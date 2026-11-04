# One-time import of past progress from Wise Old Man into data\history.jsonl, from the command line.
# The dashboard offers the same import itself (a banner after setup); this does it without the page.
# Only snapshots OLDER than your first local snapshot are imported (see wom.ps1). A backup is written first.
# Usage: powershell -ExecutionPolicy Bypass -File tools\import-wom.ps1 [-Player "Name"] [-DryRun]
param([string]$Player = "", [switch]$DryRun)
$Project = Split-Path $PSScriptRoot -Parent
. (Join-Path $Project "wom.ps1")
# Default: the name in settings.json (the same one the dashboard uses)
if (-not $Player) {
  $sf = Join-Path $Project "settings.json"
  if (Test-Path $sf) { $Player = [string]((Get-Content $sf -Raw | ConvertFrom-Json).player) }
  if (-not $Player) { Write-Host "No player name: pass -Player ""Your Name"" or set up the dashboard first."; exit 1 }
}
try { $r = Import-WomHistory $Player (Join-Path $Project "data\history.jsonl") -DryRun:$DryRun }
catch { Write-Host $_.Exception.Message; exit 1 }
Write-Host ""
Write-Host "Wise Old Man snapshots found: $($r.found) ($($r.from) -> $($r.to))"
Write-Host "Kept after removing duplicates: $($r.kept)"
if ($r.unmatched) { Write-Host "Not available on Wise Old Man (left blank): $($r.unmatched -join ', ')" }
if ($DryRun) { Write-Host "Dry run - nothing written." } else { Write-Host "Imported. Backup of the previous file: $($r.backup)" }
