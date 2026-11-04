# Builds a clean copy of the dashboard to give to someone else (or to publish): only the program, the pictures and
# the reference lists. NEVER your data: no history, bank, collection log, kills, prices, settings.json, notes.
#   powershell -ExecutionPolicy Bypass -File tools\make-release.ps1
# Output: dist\osrs-dashboard\ (the folder) and dist\osrs-dashboard.zip (the same folder, zipped).
# Everything is copied from an allow-list, then the copy is checked for anything personal; if something is found,
# no zip is made.
$ErrorActionPreference = "Stop"
$Project = Split-Path $PSScriptRoot -Parent
$Dist    = Join-Path $Project "dist"
$Out     = Join-Path $Dist "osrs-dashboard"
$Zip     = Join-Path $Dist "osrs-dashboard.zip"

# The program
$files = @(
  "start.bat", "enable-phone-access.bat", "README.md",
  "server.ps1", "plugin.ps1", "bank.ps1", "clog.ps1", "progress.ps1", "icon-outline.ps1", "wom.ps1",
  "index.html", "styles.css", "app.js",
  # Tools someone may need (re-fetch reference lists from the wiki, phone access, import old Wise Old Man history).
  # Not shipped: fetch-vendor.ps1 + fetch-item-mapping.ps1 (one-time, other hosts; their results ship instead)
  "tools\fetch-ca.ps1", "tools\fetch-ca-icons.ps1", "tools\fetch-diaries.ps1", "tools\fetch-quests.ps1", "tools\fetch-clog-layout.ps1", "tools\fetch-all-icons.ps1",
  "tools\enable-phone-access.ps1", "tools\import-wom.ps1",
  # Reference lists (the same for every player; saves the wiki from rebuilding them on the first Refresh)
  "data\bank\mapping.json",
  "data\clog\categories.json", "data\clog\images.json", "data\clog\items.json",
  "data\progress\ca-tasks.json", "data\progress\diary-tasks.json", "data\progress\miniquests.json",
  "data\progress\quest-reqs.json", "data\plugin\npc-images.json"
)
# Whole folders: fonts + chart library, and the saved pictures (so a new install doesn't download hundreds of
# pictures from the wiki on its first page load)
$folders = @("vendor", "icons")

if (Test-Path $Out) { Remove-Item $Out -Recurse -Force -Confirm:$false }
if (Test-Path $Zip) { Remove-Item $Zip -Force -Confirm:$false }
New-Item -ItemType Directory $Out | Out-Null

foreach ($f in $files) {
  $src = Join-Path $Project $f
  if (-not (Test-Path $src)) { Write-Host "  (skipped, not found: $f)"; continue }
  $dst = Join-Path $Out $f
  New-Item -ItemType Directory (Split-Path $dst -Parent) -Force | Out-Null
  Copy-Item $src $dst
}
foreach ($d in $folders) { Copy-Item (Join-Path $Project $d) (Join-Path $Out $d) -Recurse }

# Safety check: nothing personal may be in the copy. Your player name and Windows user name come from this PC,
# so the check also works for whoever runs this script.
$me = @()
$settings = Join-Path $Project "settings.json"
if (Test-Path $settings) { $me += [string]((Get-Content $settings -Raw | ConvertFrom-Json).player) }
$me = @($me | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object -Unique)
# The Windows user name only counts inside a folder path (Users\Name): as a plain word it can be in game text
# (e.g. the NPC Simon Templeton in a diary task)
$userPath = "(?i)users[\\/]+$([regex]::Escape($env:USERNAME))\b"
# Never shipped: the bank items.json / slots.json / derived.json are built from the owner's own items.
# Checked by exact path below, because the clog items.json must ship.
$banned = @("settings.json", "history*.jsonl", "credentials.properties", "kills-history.jsonl", "gear.json",
  "prices*.json", "prices-saves.jsonl", "latest.json", "CLAUDE.md", "AGENTS.md", "*.backup*", "*.before*")
$bad = @()
foreach ($pat in $banned) { $bad += @(Get-ChildItem $Out -Recurse -File -Filter $pat | ForEach-Object { $_.FullName }) }
foreach ($own in "items.json", "slots.json", "derived.json") { $p = Join-Path (Join-Path (Join-Path $Out "data") "bank") $own; if (Test-Path $p) { $bad += $p } }
$textFiles = Get-ChildItem $Out -Recurse -File -Include *.ps1, *.js, *.html, *.css, *.md, *.bat, *.json
foreach ($t in $textFiles) {
  $text = [IO.File]::ReadAllText($t.FullName)
  foreach ($word in $me) {
    if ($text -match "(?i)\b$([regex]::Escape($word))\b") { $bad += "$($t.FullName) mentions '$word'" }
  }
  if ($text -match $userPath) { $bad += "$($t.FullName) has your Windows user folder" }
  if ($text -match '[A-Za-z0-9._%+-]+@(gmail|outlook|hotmail|yahoo|icloud)\.com') { $bad += "$($t.FullName) has an email address" }
}
if ($bad.Count) {
  Write-Host "NOT released - personal things found in the copy:" -ForegroundColor Red
  $bad | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
  exit 1
}

# Zip by hand with "/" in the paths: PowerShell 5.1's Compress-Archive writes "\" and a Mac would unzip
# files literally named "data\..." instead of folders.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
if (Test-Path $Zip) { [IO.File]::Delete($Zip) }
$zipStream = [IO.Compression.ZipFile]::Open($Zip, [IO.Compression.ZipArchiveMode]::Create)
try {
  $base = Split-Path $Out -Parent
  foreach ($f in Get-ChildItem $Out -Recurse -File) {
    $entry = $f.FullName.Substring($base.Length + 1).Replace("\", "/")
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipStream, $f.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
  }
} finally { $zipStream.Dispose() }
$size = [math]::Round((Get-Item $Zip).Length / 1MB, 1)
Write-Host "Done: $Zip ($size MB)" -ForegroundColor Green
Write-Host "Checked: no history, bank, collection log, kills, prices or settings; no mention of $($me -join ', ') or your user folder."
