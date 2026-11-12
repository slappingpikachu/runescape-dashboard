# One-time download of the achievement diary tasks and requirements from the OSRS Wiki
# (12 pages), saved to data\progress\diary-tasks.json. Reference data: rerun only if Jagex
# changes the diaries.  powershell -ExecutionPolicy Bypass -File tools\fetch-diaries.ps1
$Root = Split-Path $PSScriptRoot -Parent
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$UA   = "osrs-progress-dashboard/1.0 (self-hosted OSRS progress dashboard)"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Regions = "Ardougne", "Desert", "Falador", "Fremennik", "Kandarin", "Karamja", "Kourend & Kebos",
           "Lumbridge & Draynor", "Morytania", "Varrock", "Western Provinces", "Wilderness"
$Tiers = "Easy", "Medium", "Hard", "Elite"

# Wiki markup -> plain text
function Get-CleanText([string]$s) {
  $s = $s -replace '(?s)<ref[^>]*/>', '' -replace '(?s)<ref[^>]*>.*?</ref>', ''
  $s = [regex]::Replace($s, '\{\{SCP\|([^|}]+)\|([^|}]+)[^}]*\}\}', { param($m) "$($m.Groups[2].Value) $($m.Groups[1].Value)" })
  $s = $s -replace '\{\{SCP\|[^}]*\}\}', '' -replace '\{\{NA\|([^}]*)\}\}', '$1'
  $s = $s -replace '\{\{Fairycode\|([^|}]+)[^}]*\}\}', '$1'   # fairy ring codes, e.g. BLR
  $s = $s -replace '\{\{[^{}]*\}\}', ''
  $s = $s -replace '\[\[(?:[^\]|]*\|)?([^\]]*)\]\]', '$1' -replace "'''?", '' -replace '<[^>]+>', ''
  $s = $s -replace '\[https?://\S+ ([^\]]*)\]', '$1'
  $s = $s -replace '\(\s*\)', ''   # left over from removed templates
  return ($s -replace '[ \t]+', ' ').Trim()
}

$out = [ordered]@{}
foreach ($region in $Regions) {
  $page = [uri]::EscapeDataString("$region Diary".Replace(" ", "_"))
  $res = Invoke-WebRequest -Uri "https://oldschool.runescape.wiki/api.php?action=parse&page=$page&prop=wikitext&format=json&formatversion=2" -UseBasicParsing -TimeoutSec 30 -UserAgent $UA
  $w = ($res.Content | ConvertFrom-Json).parse.wikitext
  $tierData = [ordered]@{}
  foreach ($tier in $Tiers) {
    # Overview tab: skills, quests and other requirements for the whole tier
    $tab = [regex]::Match($w, "(?s)\|-\|\s*$tier=(.*?)(?=\|-\||</tabber>)").Groups[1].Value
    # The skill box holds nested templates ({{boostable|n}}) and footnotes, so find its end by
    # counting braces: a plain "up to the first }}" match cut the list short.
    $skills = [ordered]@{}
    $noBoost = @()
    $stats = ""
    $i = $tab.IndexOf("{{DiarySkillStats")
    if ($i -ge 0) {
      $depth = 0; $j = $i
      while ($j -lt $tab.Length - 1) {
        $two = $tab.Substring($j, 2)
        if ($two -eq "{{") { $depth++; $j += 2; continue }
        if ($two -eq "}}") { $depth--; $j += 2; if ($depth -eq 0) { break }; continue }
        $j++
      }
      $stats = $tab.Substring($i, $j - $i)
    }
    foreach ($m in [regex]::Matches($stats, '(?m)^\|\s*([A-Za-z]+)\s*=\s*(\d+)\s*$')) {
      $k = $m.Groups[1].Value
      # Level 1 entries only carry an ironman footnote: no real requirement
      if ($k -notin "maxrefs", "Total" -and [int]$m.Groups[2].Value -gt 1) { $skills[$k] = [int]$m.Groups[2].Value }
    }
    # Lumbridge Elite: "Quest = {{Globals|quest points}}" (every quest point), ask the wiki for the number
    $qp = [regex]::Match($stats, '(?m)^\|\s*Quest\s*=\s*(\{\{.*\}\})\s*$')
    if ($qp.Success) {
      $x = Invoke-WebRequest -Uri ("https://oldschool.runescape.wiki/api.php?action=expandtemplates&prop=wikitext&format=json&formatversion=2&text=" + [uri]::EscapeDataString($qp.Groups[1].Value)) -UseBasicParsing -TimeoutSec 30 -UserAgent $UA
      $n = (($x.Content | ConvertFrom-Json).expandtemplates.wikitext -replace '[^\d]', '')
      if ($n) { $skills["Quest"] = [int]$n }
    }
    foreach ($m in [regex]::Matches($stats, '(?m)^\|\s*([A-Za-z]+)Notes\s*=.*\{\{[Bb]oostable\|n\}\}')) {
      if ($skills.Contains($m.Groups[1].Value)) { $noBoost += $m.Groups[1].Value }
    }
    $quests = @([regex]::Matches($tab, 'data-rowid="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    if ($tab -match '\[\[Quests/List\|All quests\]\]') { $quests += "All quests" }
    $extra = @()
    $add = [regex]::Match($tab, '(?s)!\s*Additional requirements(.*?)\n\|\}').Groups[1].Value
    foreach ($line in ($add -split "\n\|-\s*\n")) { $t = Get-CleanText ($line -replace '^\s*\|', ''); if ($t) { $extra += $t } }

    # Task table: rows of "N. task" | requirements
    $table = [regex]::Match($w, "(?s)data-diary-tier=""$tier""[^\n]*\n(.*?)\n\|\}").Groups[1].Value
    $tasks = @()
    foreach ($row in ($table -split "\n\|-[^\n]*\n")) {
      if ($row -notmatch '(?s)^\|\s*\d+\.') { continue }
      $cells = $row -split "\n\|(?=[^-}])", 2
      $text = $cells[0] -replace '^\|\s*\d+\.\s*', ''
      $note = ""
      if ($text -match "(?s)^(.*?)\n''?Note:\s*(.*)$") { $text = $Matches[1]; $note = $Matches[2] }
      $req = if ($cells.Count -gt 1) { @(($cells[1] -split "\n\*") | ForEach-Object { Get-CleanText $_ } | Where-Object { $_ -and $_ -ne "None" }) } else { @() }
      $tasks += [ordered]@{ task = (Get-CleanText $text); note = (Get-CleanText $note); req = $req }
    }
    $tierData[$tier] = [ordered]@{ skills = $skills; noBoost = $noBoost; quests = $quests; extra = $extra; tasks = $tasks }
  }
  $out[$region] = $tierData
  "{0}: {1}" -f $region, (($Tiers | ForEach-Object { "$_ $($tierData[$_].tasks.Count)" }) -join ", ")
  Start-Sleep -Milliseconds 500
}
$dir = Join-Path $Root "data\progress"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
[IO.File]::WriteAllText((Join-Path $dir "diary-tasks.json"), ($out | ConvertTo-Json -Depth 8 -Compress), $Utf8)
