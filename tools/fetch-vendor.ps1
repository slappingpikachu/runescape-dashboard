# One-time: saves Chart.js and the Inter / Cinzel fonts into .\vendor so the page loads nothing
# from the internet (server.ps1 serves them from disk). Run again only to replace them.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Root   = Split-Path $PSScriptRoot
$Vendor = Join-Path $Root "vendor"
$Fonts  = Join-Path $Vendor "fonts"
New-Item -ItemType Directory -Force $Fonts | Out-Null

Invoke-WebRequest "https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js" -UseBasicParsing -OutFile (Join-Path $Vendor "chart.umd.min.js")

# Google Fonts sends woff2 to modern browsers; only the latin subset is kept (the page is English)
$ua  = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
$css = (Invoke-WebRequest "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=Cinzel:wght@600;700&display=swap" -UseBasicParsing -UserAgent $ua).Content
Get-ChildItem $Fonts -File | Remove-Item
$out = @(); $saved = @{}   # variable fonts: every weight of a family is the same file
foreach ($m in [regex]::Matches($css, '/\* (?<subset>[a-z-]+) \*/\s*(?<rule>@font-face \{[^}]*\})')) {
  if ($m.Groups["subset"].Value -ne "latin") { continue }
  $rule = $m.Groups["rule"].Value
  $url  = [regex]::Match($rule, 'url\((https://[^)]+\.woff2)\)').Groups[1].Value
  if (-not $saved[$url]) {
    $fam  = [regex]::Match($rule, "font-family: '([^']+)'").Groups[1].Value.ToLower()
    $file = if ($saved.Values -contains "$fam.woff2") { "$fam-$($saved.Count).woff2" } else { "$fam.woff2" }
    Invoke-WebRequest $url -UseBasicParsing -OutFile (Join-Path $Fonts $file)
    $saved[$url] = $file
  }
  $out += $rule.Replace($url, "/vendor/fonts/$($saved[$url])")
}
# One rule per file with the weight range (so the phone snapshot embeds each font once)
$out = $out | Group-Object { [regex]::Match($_, 'url\(([^)]+)\)').Groups[1].Value } | ForEach-Object {
  $w = $_.Group | ForEach-Object { [int][regex]::Match($_, 'font-weight: (\d+)').Groups[1].Value } | Sort-Object
  $_.Group[0] -replace 'font-weight: \d+', "font-weight: $($w[0]) $($w[-1])"
}
[IO.File]::WriteAllText((Join-Path $Vendor "fonts.css"), ($out -join "`n") + "`n", (New-Object Text.UTF8Encoding $false))
Get-ChildItem $Vendor -Recurse -File | ForEach-Object { "{0,-28} {1,8:N0} bytes" -f $_.Name, $_.Length }
