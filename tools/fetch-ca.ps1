# One-time download of the combat achievement task list from the OSRS Wiki (bucket API, ~2 requests)
# plus the points needed for each reward tier, saved to data\progress\ca-tasks.json. Which tasks are
# done comes from the OSRS Data Sync plugin on Refresh. Reference data: rerun when Jagex adds tasks.
#   powershell -ExecutionPolicy Bypass -File tools\fetch-ca.ps1
$Root = Split-Path $PSScriptRoot -Parent
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$UA   = "osrs-progress-dashboard/1.0 (self-hosted OSRS progress dashboard)"
$Api  = "https://oldschool.runescape.wiki/api.php"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Get-Json([string]$query) {
  (Invoke-WebRequest -Uri "${Api}?$query" -UseBasicParsing -TimeoutSec 30 -UserAgent $UA).Content | ConvertFrom-Json
}

# Tasks: id = the id the plugin reports for a finished task
$tasks = @()
for ($off = 0; ; $off += 500) {
  $q = "bucket('combat_achievement').select('id','name','monster','task','tier','type').limit(500).offset($off).run()"
  $rows = @((Get-Json "action=bucket&format=json&query=$([uri]::EscapeDataString($q))").bucket)
  foreach ($r in $rows) {
    $tasks += [ordered]@{ id = [int]$r.id; name = [string]$r.name; monster = [string]$r.monster; task = [string]$r.task; tier = [string]$r.tier; type = [string]$r.type }
  }
  if ($rows.Count -lt 500) { break }
  Start-Sleep -Milliseconds 500
}
$tasks = @($tasks | Sort-Object { $_.id })

# Points needed per reward tier (wiki globals). Grandmaster = every task, so the page works it out.
$tiers = "Easy", "Medium", "Hard", "Elite", "Master"
$text = ($tiers | ForEach-Object { "{{Globals|ca $($_.ToLower()) points}}" }) -join ","
$vals = (Get-Json "action=expandtemplates&prop=wikitext&format=json&text=$([uri]::EscapeDataString($text))").expandtemplates.wikitext -split ","
$points = [ordered]@{}
for ($i = 0; $i -lt $tiers.Count; $i++) { $points[$tiers[$i]] = [int]($vals[$i] -replace '[^0-9]', '') }

$dir = Join-Path $Root "data\progress"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
$out = [ordered]@{ fetched = (Get-Date).ToUniversalTime().ToString("o"); points = $points; tasks = $tasks }
[IO.File]::WriteAllText((Join-Path $dir "ca-tasks.json"), ($out | ConvertTo-Json -Depth 5 -Compress), $Utf8)
"$($tasks.Count) tasks; tier points: $(($points.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')"
