# One-time download of icons for the combat achievement monsters the hiscores don't track (slayer
# monsters, Galvek, ...). Uses the monster's chathead or picture from the OSRS Wiki, trims it, shrinks it
# to 24px, adds the white outline and saves icons\ca\<slug>.png (served from disk by server.ps1, embedded
# in the phone snapshot). Monsters that already have an icon (hiscores bosses + CA_BOSS_ALIAS / CA_ICON_ALIAS in app.js)
# are skipped, and so are files that already exist. Rerun after tools\fetch-ca.ps1 adds new monsters.
#   powershell -ExecutionPolicy Bypass -File tools\fetch-ca-icons.ps1
$Root = Split-Path $PSScriptRoot -Parent
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$UA   = "osrs-progress-dashboard/1.0 (self-hosted OSRS progress dashboard)"
$Api  = "https://oldschool.runescape.wiki/api.php"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $Root "icon-outline.ps1")
function Get-Json([string]$query) {
  (Invoke-WebRequest -Uri "${Api}?$query" -UseBasicParsing -TimeoutSec 30 -UserAgent $UA).Content | ConvertFrom-Json
}
$slug = { param($s) ($s.ToLower() -replace '[^a-z0-9]', '') }

# Monsters that already have an icon: hiscores bosses (icons\game) and the aliases in app.js
$key = { param($s) (($s -replace '^The ', '').ToLower() -replace '[^a-z0-9]', '') }
$last = [IO.File]::ReadAllLines((Join-Path $Root "data\history.jsonl"), $Utf8) | Where-Object { $_.Trim() } | Select-Object -Last 1 | ConvertFrom-Json
$bosses = @{}; foreach ($a in $last.d.activities) { $bosses[(& $key $a.name)] = 1 }
$appJs = [IO.File]::ReadAllText((Join-Path $Root "app.js"), $Utf8)
$aliased = [regex]::Matches($appJs, '(?s)const CA_(?:BOSS|ICON)_ALIAS = \{(.*?)\};') | ForEach-Object {
  [regex]::Matches($_.Groups[1].Value, '"([^"]+)":') | ForEach-Object { $_.Groups[1].Value }
}

# Where the picture is when it isn't the monster's own page
$Source = @{
  "Giants"                       = "Fire giant"
  "TzHaar-Ket-Rak's Challenges"  = "File:TzHaar-Ket-Rak chathead.png"
  "Glough"                       = "File:Glough chathead.png"
  "Fragment of Seren"            = "File:Fragment of Seren chathead.png"
}

$ca = [IO.File]::ReadAllText((Join-Path $Root "data\progress\ca-tasks.json"), $Utf8) | ConvertFrom-Json
$dir = Join-Path $Root "icons\ca"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
foreach ($m in ($ca.tasks.monster | Sort-Object -Unique)) {
  if ($m -eq "None" -or $bosses[(& $key $m)] -or $aliased -contains $m) { continue }
  $file = Join-Path $dir "$(& $slug $m).png"
  if (Test-Path $file) { continue }

  # The wiki file: given above, or the first image of the monster's infobox
  $src = if ($Source[$m]) { $Source[$m] } else { $m }
  if ($src -notlike "File:*") {
    $q = "bucket('infobox_monster').select('page_name','image').where('page_name','$($src -replace "'", "\'")').limit(5).run()"
    $rows = @((Get-Json "action=bucket&format=json&query=$([uri]::EscapeDataString($q))").bucket)
    if (-not $rows.Count) {   # wiki page names are sentence case ("Aberrant spectre")
      $alt = $src.Substring(0, 1) + $src.Substring(1).ToLower()
      $q = "bucket('infobox_monster').select('page_name','image').where('page_name','$($alt -replace "'", "\'")').limit(5).run()"
      $rows = @((Get-Json "action=bucket&format=json&query=$([uri]::EscapeDataString($q))").bucket)
    }
    $img = @($rows | ForEach-Object { @($_.image) } | Where-Object { $_ })[0]
    if (-not $img) { "  $m - no wiki image found"; continue }
    $src = if ($img -like "File:*") { $img } else { "File:$img" }
  }
  $url = "https://oldschool.runescape.wiki/images/" + [uri]::EscapeDataString(($src -replace '^File:', '' -replace ' ', '_'))
  try { $bytes = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -UserAgent $UA).Content }
  catch { "  $m - download failed ($src)"; continue }

  # Trim the transparent border, then fit into 24x24
  $bmp = [System.Drawing.Bitmap]::new([IO.MemoryStream]::new($bytes))
  $minX = $bmp.Width; $minY = $bmp.Height; $maxX = -1; $maxY = -1
  for ($y = 0; $y -lt $bmp.Height; $y++) { for ($x = 0; $x -lt $bmp.Width; $x++) {
    if ($bmp.GetPixel($x, $y).A -gt 20) { if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }; if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y } }
  } }
  $w = $maxX - $minX + 1; $h = $maxY - $minY + 1
  $scale = [Math]::Min(1.0, 24.0 / [Math]::Max($w, $h))
  $nw = [Math]::Max(1, [int][Math]::Round($w * $scale)); $nh = [Math]::Max(1, [int][Math]::Round($h * $scale))
  $small = [System.Drawing.Bitmap]::new($nw, $nh)
  $g = [System.Drawing.Graphics]::FromImage($small)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.DrawImage($bmp, [System.Drawing.Rectangle]::new(0, 0, $nw, $nh), $minX, $minY, $w, $h, [System.Drawing.GraphicsUnit]::Pixel)
  $ms = [IO.MemoryStream]::new(); $small.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $small.Dispose(); $bmp.Dispose()
  [IO.File]::WriteAllBytes($file, (Add-IconOutline $ms.ToArray()))
  "  $m <- $src"
  Start-Sleep -Milliseconds 400
}
