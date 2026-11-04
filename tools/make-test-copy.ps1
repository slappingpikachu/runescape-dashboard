# Makes a throwaway copy of the dashboard with FAKE history (walking backwards from
# the newest real snapshot) so UI changes can be tested without touching data\history.jsonl.
# Usage: powershell -ExecutionPolicy Bypass -File tools\make-test-copy.ps1 [-OutDir path]
param([string]$OutDir = (Join-Path $env:TEMP "osrs-dashboard-test"))
$Project = Split-Path $PSScriptRoot -Parent
$real = [IO.File]::ReadAllLines((Join-Path $Project "data\history.jsonl")) | Where-Object { $_.Trim() } | Select-Object -Last 1
$xpt = @(0, 0); $pts = 0
for ($l = 1; $l -lt 126; $l++) { $pts += [math]::Floor($l + 300 * [math]::Pow(2, $l / 7)); $xpt += [math]::Floor($pts / 4) }
function LevelFor($xp) { $l = 1; while ($l -lt 99 -and $xp -ge $xpt[$l + 1]) { $l++ }; $l }

$rand = New-Object System.Random 7
$snap = $real | ConvertFrom-Json
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add(($snap | ConvertTo-Json -Depth 6 -Compress))
$now = [datetime]::Parse($snap.t).ToUniversalTime()
$offsetsH = @(3, 20, 30, 52, 75, 100, 125, 170, 196, 240, 290, 335, 380, 430, 480)
$trainable = @("Slayer","Ranged","Magic","Defence","Herblore","Construction","Farming","Agility","Sailing","Prayer","Attack")
$bossPool = @("Vorkath","The Corrupted Gauntlet","Brutus","Phantom Muspah","The Leviathan","Tombs of Amascut")
foreach ($h in $offsetsH) {
  $snap = $snap | ConvertTo-Json -Depth 6 -Compress | ConvertFrom-Json
  $snap.t = $now.AddHours(-$h).ToString("o")
  $total = 0
  $picks = $trainable | Sort-Object { $rand.Next() } | Select-Object -First ($rand.Next(1, 4))
  foreach ($sk in $snap.d.skills) {
    if ($sk.name -eq "Overall") { continue }
    if ($picks -contains $sk.name -and $sk.level -lt 99) {
      $sk.xp = [math]::Max(0, $sk.xp - $rand.Next(40000, 260000)); $sk.level = LevelFor $sk.xp
    }
    $total += $sk.xp
  }
  $o = $snap.d.skills | Where-Object name -eq "Overall"
  $o.xp = $total; $o.level = ($snap.d.skills | Where-Object name -ne "Overall" | Measure-Object level -Sum).Sum
  $boss = $bossPool[$rand.Next($bossPool.Count)]
  foreach ($a in $snap.d.activities) {
    if ($a.name -eq $boss -and $a.score -gt 10) { $a.score -= $rand.Next(3, 25) }
    if ($h % 3 -eq 0 -and $a.name -eq "Clue Scrolls (elite)") { $a.score -= 1 }
    if ($h % 3 -eq 0 -and $a.name -eq "Clue Scrolls (all)") { $a.score -= 1 }
  }
  [void]$lines.Insert(0, ($snap | ConvertTo-Json -Depth 6 -Compress))
}

New-Item -ItemType Directory -Force (Join-Path $OutDir "data") | Out-Null
foreach ($f in "index.html", "styles.css", "app.js") { Copy-Item (Join-Path $Project $f) $OutDir -Force }
Copy-Item (Join-Path $Project "*.ps1") $OutDir -Force   # server.ps1 + the clog/progress/bank/icon scripts it loads
foreach ($d in "icons", "vendor") { if (Test-Path (Join-Path $Project $d)) { Copy-Item (Join-Path $Project $d) $OutDir -Recurse -Force } }
# The player name: without settings.json the copy only shows the first-start setup card
$settings = Join-Path $Project "settings.json"
if (Test-Path $settings) {   # womAsked: the fake history has no Wise Old Man lines, so the copy would offer the import
  $st = [IO.File]::ReadAllText($settings) | ConvertFrom-Json
  [IO.File]::WriteAllText((Join-Path $OutDir "settings.json"), (@{ player = $st.player; womAsked = $true } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}
# Collection log / quests / bank / kill history are copied as they are (only the hiscores history is faked)
foreach ($d in "clog", "progress", "bank", "plugin") {
  $src = Join-Path $Project "data\$d"
  if (Test-Path $src) { Copy-Item $src (Join-Path $OutDir "data") -Recurse -Force }
}
[IO.File]::WriteAllLines((Join-Path $OutDir "data\history.jsonl"), [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
"$($lines.Count) fake snapshots written to $OutDir"
"Start it with: powershell -ExecutionPolicy Bypass -File `"$OutDir\server.ps1`" -Port 8799"
