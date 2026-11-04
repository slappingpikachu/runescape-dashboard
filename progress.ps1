# Quests, achievement diaries and combat achievements for the page. The data comes only from the OSRS Data Sync
# RuneLite plugin (plugin.ps1 Update-PluginProgress, on Refresh). Dot-sourced by server.ps1; needs $DataDir, $Utf8.
#
# data\progress\latest.json    {"v":3,"src":"plugin","timestamp":..,"quests":{name:0|1|2},
#                               "diaries":{region:{tier:[done|null,total,"1101.."]}},"ca":[finished task ids]}
#                               (older v2 lines in history.jsonl also have per-task diary flags)
# data\progress\diary-tasks.json  task text + requirements from the wiki (tools\fetch-diaries.ps1, one-time)
# data\progress\ca-tasks.json  combat achievement tasks + tier points from the wiki (tools\fetch-ca.ps1, one-time)
# data\progress\history.jsonl  the same, one line per change (to spot newly finished tasks)

$ProgressDir = Join-Path $DataDir "progress"

# A file from data\progress as it is, or $missing when it isn't there yet
function Read-ProgressJson([string]$name, [string]$missing = "null") {
  $f = Join-Path $ProgressDir $name
  if (Test-Path $f) { return [IO.File]::ReadAllText($f, $Utf8) }
  return $missing
}
function Get-ProgressJson { Read-ProgressJson "latest.json" }
function Get-DiaryTasksJson { Read-ProgressJson "diary-tasks.json" }
# Quest requirements from the OSRS Wiki (tools\fetch-quests.ps1)
function Get-QuestReqsJson { Read-ProgressJson "quest-reqs.json" }
# Miniquest names (OSRS Wiki category, fetched once), to split them from quests
function Get-MiniquestsJson { Read-ProgressJson "miniquests.json" "[]" }
# Combat achievement tasks + tier points (OSRS Wiki, fetched once by tools\fetch-ca.ps1)
function Get-CaTasksJson { Read-ProgressJson "ca-tasks.json" }
# GET /api/ca-history: [{"t":sync timestamp,"ca":[ids]},...] from history.jsonl, one entry per
# change of the finished-task list (lines saved before combat achievements were tracked have no "ca")
function Get-CaHistoryJson {
  $f = Join-Path $ProgressDir "history.jsonl"
  if (-not (Test-Path $f)) { return "[]" }
  $out = @(); $prev = $null
  foreach ($line in [IO.File]::ReadAllLines($f, $Utf8)) {
    $ca = [regex]::Match($line, '"ca":\[[0-9,]*\]').Value
    if (-not $ca -or $ca -eq $prev) { continue }
    $prev = $ca
    $out += "{""t"":""$([regex]::Match($line, '"timestamp":"([^"]*)"').Groups[1].Value)"",$ca}"
  }
  return "[" + ($out -join ",") + "]"
}
