# Offline integration tests: OSRS Data Sync plugin files -> the dashboard readers (plugin.ps1, bank.ps1, clog.ps1).
# Usage: powershell -ExecutionPolicy Bypass -File tools\test-plugin-files.ps1   (~15 s, prints a pass/fail table)
# Uses the player in settings.json; reads (never changes) that player's real plugin folder and data\ reference lists.
# Works on copies in a temp folder; the network is stubbed out; the real data and plugin folders are only read.
# -Impl app runs the same checks against the desktop app (app\src-tauri, built with cargo build) instead of the scripts.
param([string]$Project = (Split-Path $PSScriptRoot -Parent), [ValidateSet("ps", "app")][string]$Impl = "ps",
  [string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) "app\src-tauri\target\debug\osrs-dashboard.exe"))
$ErrorActionPreference = "Stop"
$Work = Join-Path $env:TEMP "osrs-integ-test"
if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
New-Item -ItemType Directory "$Work\data", "$Work\icons", "$Work\plugin-data" | Out-Null
$Player = ([IO.File]::ReadAllText((Join-Path $Project "settings.json")) | ConvertFrom-Json).player

# Reference data the readers need (names, categories, task lists): copied, never written back
foreach ($d in "clog", "bank", "progress") { New-Item -ItemType Directory "$Work\data\$d" | Out-Null }
foreach ($f in "categories.json", "items.json", "images.json") { Copy-Item "$Project\data\clog\$f" "$Work\data\clog\" }
foreach ($f in "items.json", "mapping.json", "derived.json", "slots.json") { Copy-Item "$Project\data\bank\$f" "$Work\data\bank\" }
Copy-Item "$Project\data\progress\diary-tasks.json" "$Work\data\progress\"

$Root = $Work; $DataDir = "$Work\data"; $Utf8 = New-Object System.Text.UTF8Encoding($false)
. "$Project\icon-outline.ps1"; . "$Project\clog.ps1"; . "$Project\progress.ps1"; . "$Project\bank.ps1"; . "$Project\plugin.ps1"
$RealPlugin = Get-PluginDir   # the real folder (plugin.ps1 rule), read only
$RealPlayer = $Player
$PluginRoot = "$Work\plugin-data"
# Offline: every download fails like a dead connection would
function Get-Web([string]$url) { $script:WebCalls++; throw "offline (test)" }
function Invoke-WebRequest { $script:WebCalls++; throw "offline (test)" }
function Start-Sleep { }
$script:WebCalls = 0
if ($Impl -eq "app") {
  # The app does each Refresh step (cli.rs --step); offline = an empty recording, so every download fails
  [Console]::OutputEncoding = $Utf8
  [IO.File]::WriteAllText("$Work\settings.json", "{""player"":$(ConvertTo-Json $Player)}", $Utf8)
  New-Item -ItemType Directory "$Work\tape" | Out-Null
  $env:OSRS_PLUGIN_ROOT = $PluginRoot; $env:OSRS_DASH_NET_REPLAY = "$Work\tape"; $env:OSRS_DASH_NO_WAIT = "1"
  function Invoke-AppStep { $o = (& $Exe --root $Work --step @args) -join "`n"; if ($o.StartsWith("ERROR: ")) { throw $o.Substring(7) }; $o }
  function Update-PluginProgress { Invoke-AppStep progress }
  function Update-PluginLootGaps { Invoke-AppStep lootgaps }
  function Update-PluginClog { Invoke-AppStep clog }
  function Update-Bank { Invoke-AppStep bank }
  function Update-PluginKills([string]$t) { Invoke-AppStep kills $t }
  function Get-PluginJson { & $Exe --root $Work --cli GET /api/plugin --out "$Work\api.json" 2>$null | Out-Null; [IO.File]::ReadAllText("$Work\api.json", $Utf8) }
}

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$name, [scriptblock]$test) {
  try { $r = & $test; $ok = $r -ne $false; $msg = if ($r -is [string]) { $r } else { "" } }
  catch { $ok = $false; $msg = $_.Exception.Message }
  $results.Add([pscustomobject]@{ ok = $ok; test = $name; note = $msg })
}
function Parse([string]$json) { $json | ConvertFrom-Json }   # throws on invalid JSON
function Set-PluginFiles([hashtable]$files) {
  $dir = Get-PluginDir
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
  New-Item -ItemType Directory $dir | Out-Null
  foreach ($k in $files.Keys) { [IO.File]::WriteAllText((Join-Path $dir $k), $files[$k], $Utf8) }
}
function Reset-Data { foreach ($f in "$DataDir\clog\history.jsonl", "$DataDir\bank\history.jsonl", "$DataDir\bank\gear.json", "$DataDir\progress\latest.json", "$DataDir\progress\history.jsonl", "$DataDir\plugin\kills-history.jsonl", "$DataDir\plugin\loot-base.json", "$DataDir\plugin\loot-gaps.jsonl") { if (Test-Path $f) { Remove-Item $f } } }

# ---------------------------------------------------------------- 1. the real plugin files
$dir = Get-PluginDir; New-Item -ItemType Directory $dir | Out-Null
Copy-Item "$RealPlugin\*" $dir
Check "real: /api/plugin is valid JSON" { $j = Parse (Get-PluginJson); "drops=$(@($j.drops).Count) killHistory=$(@($j.killHistory).Count) npcIcons=$(@($j.npcIcons).Count)" }
Check "real: every loot.jsonl line reaches the page" {
  $lines = @([IO.File]::ReadAllLines("$dir\loot.jsonl") | Where-Object { $_.Trim() })
  $j = Parse (Get-PluginJson); if (@($j.drops).Count -ne $lines.Count) { throw "$($lines.Count) lines, $(@($j.drops).Count) sent" }; "$($lines.Count) lines" }
Check "real: progress -> latest.json" { $m = Update-PluginProgress; $l = Parse ([IO.File]::ReadAllText("$DataDir\progress\latest.json")); "$m | quests=$(@($l.quests.PSObject.Properties).Count) ca=$(@($l.ca).Count)" }
Check "real: progress 2nd run = no change" { $m = Update-PluginProgress; if ($m -ne "Progress: no change") { throw $m }; $m }
Check "real: diaries keep the page's shape" { $l = Parse ([IO.File]::ReadAllText("$DataDir\progress\latest.json"))
  foreach ($r in $l.diaries.PSObject.Properties) { foreach ($t in "Easy", "Medium", "Hard", "Elite") { $v = @($r.Value.$t); if ($v.Count -ne 3) { throw "$($r.Name) $t = $($v -join ',')" } } }; "12 regions x 4 tiers" }
Check "real: clog -> history line" { $m = Update-PluginClog; $last = [IO.File]::ReadAllLines("$DataDir\clog\history.jsonl")[-1]; $p = Parse $last; "$m | items=$(@($p.items.PSObject.Properties).Count)" }
Check "real: clog 2nd run = no change" { $m = Update-PluginClog; if ($m -notmatch "no change") { throw $m }; "ok" }
Check "real: clog counts = max(plugin, saved)" { $c = Parse ([IO.File]::ReadAllText("$dir\clog.json")); $p = Parse ([IO.File]::ReadAllLines("$DataDir\clog\history.jsonl")[-1])
  $bad = @(foreach ($it in $c.items.PSObject.Properties) { if ([int]$it.Value -gt 0 -and [int]$p.items.($it.Name)[0] -lt [int]$it.Value) { $it.Name } }); if ($bad) { throw "lower counts: $bad" }; "ok" }
Check "real: containers -> bank line" { $m = Update-Bank; $p = Parse ([IO.File]::ReadAllLines("$DataDir\bank\history.jsonl")[-1]); $b = Parse ([IO.File]::ReadAllText("$DataDir\bank\gear.json"))
  "$($m.Split('-')[0].Trim()) | items=$(@($p.items).Count) worn=$(@($p.worn).Count) carried=$(@($p.carried).Count) pouch=$(@($p.pouch).Count) inv slots=$(@($b.inv).Count)" }
Check "real: bank 2nd run = no change" { $m = Update-Bank; if ($m -notmatch "no change") { throw $m.Substring(0, 80) }; "ok" }
Check "real: bank totals = plugin totals" { $c = Parse ([IO.File]::ReadAllText("$dir\containers.json")); $p = Parse ([IO.File]::ReadAllLines("$DataDir\bank\history.jsonl")[-1])
  $sum = { param($l) $s = 0; foreach ($x in @($l)) { if ($x -and [int]$x[0] -ne 20594) { $s += [long]$x[1] } }; $s }
  foreach ($k in @(@("bank", "items"), @("equipment", "worn"), @("inventory", "carried"))) { $a = & $sum $c.($k[0]); $b = & $sum $p.($k[1]); if ($a -ne $b) { throw "$($k[0]) $a vs $b" } }; "bank/worn/carried quantities match" }
Check "real: inventory slots kept" { $c = Parse ([IO.File]::ReadAllText("$dir\containers.json")); $b = Parse ([IO.File]::ReadAllText("$DataDir\bank\gear.json"))
  foreach ($i in @($c.inventory)) { $hit = @($b.inv | Where-Object { $_[0] -eq $i[2] -and $_[1] -eq $i[0] }); if (-not $hit) { throw "slot $($i[2]) id $($i[0]) missing" } }; "$(@($c.inventory).Count) items in their slots" }
Check "real: kills -> kills-history" { $m = Update-PluginKills "2026-11-02T12:00:00.0000000Z"; $l = Parse ([IO.File]::ReadAllLines($KillHistoryFile)[-1]); "$($m.Split(';')[0]) | sources=$(@($l.k.PSObject.Properties).Count)" }
Check "real: kills 2nd run = no new kills" { $m = Update-PluginKills "2026-11-02T12:05:00.0000000Z"; if ($m -notmatch "no new kills") { throw $m.Substring(0, 80) }; "ok" }
Check "real: kill keys match Loot Tracker names exactly" { $kc = Parse ([IO.File]::ReadAllText("$dir\killcounts.json")); $l = Parse ([IO.File]::ReadAllLines($KillHistoryFile)[-1])
  $want = @(foreach ($t in $kc.lootTracker.PSObject.Properties) { foreach ($s in $t.Value.PSObject.Properties) { "$($t.Name)|$($s.Name)" } })
  $have = @($l.k.PSObject.Properties.Name); $miss = @($want | Where-Object { $have -notcontains $_ }); if ($miss) { throw "missing: $($miss[0..4] -join ', ')" }; "$($want.Count) keys" }
Check "real: /api/plugin still valid after Refresh" { [void](Parse (Get-PluginJson)); "ok" }

# ---------------------------------------------------------------- 2. edge cases the plugin can write
# Diary task flags: a partial tier gets its count + flags, a finished tier stays all done, a wrong-length or missing
# flag string stays unknown (older plugin)
Reset-Data
Set-PluginFiles @{ "progress.json" = '{"quests":{"Cook''s Assistant":2},"questPoints":1,"diaries":{"Kandarin":{"Easy":true,"Medium":false,"Hard":false,"Elite":false}},' +
  '"diaryTasks":{"Kandarin":{"Easy":"00000000000","Medium":"10100000000001","Hard":"101","Elite":""}},"ca":[]}' }
Check "diary tasks: partial, finished, bad length, none" { [void](Update-PluginProgress); $k = (Parse ([IO.File]::ReadAllText("$DataDir\progress\latest.json"))).diaries.Kandarin
  $want = @{ Easy = "11,11,11111111111"; Medium = "3,14,10100000000001"; Hard = ",11,"; Elite = ",7," }
  foreach ($t in $want.Keys) { $got = @($k.$t) -join ","; if ($got -ne $want[$t]) { throw "$t = $got (want $($want[$t]))" } }; "ok" }

$now = [DateTime]::UtcNow
$iso = { param($d) $d.ToString("yyyy-MM-ddTHH:mm:ss.fffffff00Z") }   # Java Instant style: 9 fraction digits
Reset-Data
Set-PluginFiles @{
  "clog.json" = "{""updated"":""$(& $iso $now.AddMinutes(-30))"",""obtained"":1,""items"":{""4151"":1},""newByName"":{}}"
  "loot.jsonl" = @(
    "{""t"":""$(& $iso $now.AddMinutes(-60))"",""source"":""Abyssal demon"",""type"":""NPC"",""value"":1,""items"":[[4151,1,1]]}",   # before the clog.json write: already counted
    "{""t"":""$(& $iso $now.AddMinutes(-10))"",""source"":""K\u0027ril Tsutsaroth"",""type"":""NPC"",""value"":5,""items"":[[11816,1,5]],""kc"":12}",
    "{""t"":""$(& $iso $now.AddMinutes(-5))"",""source"":""Abyssal demon"",""type"":""NPC"",""value"":2,""items"":[[4151,2,1]]}",
    "{""t"":""$($now.AddMinutes(-3).ToString("yyyy-MM-ddTHH:mm:ssZ"))"",""source"":""Whole \u003d seconds"",""type"":""EVENT"",""value"":0,""items"":[]}",
    "{""t"":""$(& $iso $now)"",""source"":""Half writ") -join "`n"   # a line still being written
}
Check "edge: 9-digit / whole-second times parse in PowerShell" { foreach ($s in "2026-11-02T08:28:29.727679100Z", "2026-11-02T08:28:29Z", "2026-11-02T08:28:29.7Z") { [void][DateTime]::Parse($s) }; "ok" }
Check "edge: half-written last line is skipped, not sent" { $j = Parse (Get-PluginJson); "$(@($j.drops).Count) of 5 lines sent" }
Check "edge: apostrophe name arrives unescaped on the page" { $j = Parse (Get-PluginJson); $n = @($j.drops | ForEach-Object { $_.source }); if ($n -notcontains "K'ril Tsutsaroth") { throw "names: $($n -join ' / ')" }; "K'ril Tsutsaroth" }
Check "edge: log-item drops after clog.json count once" { [void](Update-PluginClog); $p = Parse ([IO.File]::ReadAllLines("$DataDir\clog\history.jsonl")[-1]); $q = $p.items.'4151'[0]; if ($q -ne 3) { throw "whip count $q, want 3 (1 + 2 dropped later)" }; "whip = 3" }
Check "edge: same drops on the next Refresh aren't added again" { [void](Update-PluginClog); $p = Parse ([IO.File]::ReadAllLines("$DataDir\clog\history.jsonl")[-1]); $q = $p.items.'4151'[0]; if ($q -ne 3) { throw "whip count $q" }; "still 3" }

Check "edge: the finished line is counted on the next Refresh" {
  $f = Join-Path (Get-PluginDir) "loot.jsonl"; $l = [IO.File]::ReadAllLines($f); $l[-1] = "{""t"":""$(& $iso $now)"",""source"":""Abyssal demon"",""type"":""NPC"",""value"":1,""items"":[[4151,1,1]]}"
  [IO.File]::WriteAllLines($f, $l); [void](Update-PluginClog); $p = Parse ([IO.File]::ReadAllLines("$DataDir\clog\history.jsonl")[-1]); $q = $p.items.'4151'[0]; if ($q -ne 4) { throw "whip count $q, want 4" }; "whip = 4" }

Set-PluginFiles @{ "progress.json" = ""; "killcounts.json" = "{}"; "clog.json" = "{""items"":{}}"; "containers.json" = "{""updated"":""$(& $iso $now)""}" }
Check "edge: an EMPTY plugin file keeps /api/plugin valid" { [void](Parse (Get-PluginJson)); "ok" }
Check "edge: containers without a bank -> no bank line" { Reset-Data; $m = Update-Bank; if ($m -notmatch "nothing from") { throw $m }; "ok" }
Set-PluginFiles @{ "containers.json" = "{""updated"":""$(& $iso $now)"",""bank"":[],""bankAt"":0,""inventory"":[],""equipment"":[],""runePouch"":[],""ge"":[]}" }
Check "edge: a really empty bank (bank: []) is saved" { Reset-Data; $m = Update-Bank; if ($m -match "nothing from") { throw "treated as never opened" }; "ok" }
Set-PluginFiles @{ "containers.json" = "{""updated"":""$(& $iso $now)"",""bank"":[[995,10,0]],""bankAt"":1793608110328,""inventory"":[[4151,1,27]],""equipment"":[[1163,1,0]]}" }
Check "edge: old plugin file without runePouch" { Reset-Data; [void](Update-Bank); $p = Parse ([IO.File]::ReadAllLines("$DataDir\bank\history.jsonl")[-1]); if ($p.PSObject.Properties['pouch']) { throw "pouch written" }; "no pouch field" }
Check "edge: single-item lists stay lists" { $p = Parse ([IO.File]::ReadAllLines("$DataDir\bank\history.jsonl")[-1]); foreach ($k in "items", "worn", "carried") { if (-not ($p.$k[0] -is [array])) { throw "$k = $($p.$k | ConvertTo-Json -Compress)" } }; "items/worn/carried = [[id,qty]]" }
Check "edge: inventory slot 27 (last) kept" { $b = Parse ([IO.File]::ReadAllText("$DataDir\bank\gear.json")); if ("$($b.inv[0] -join ',')" -ne "27,4151,1") { throw ($b.inv | ConvertTo-Json -Compress) }; "ok" }
Set-PluginFiles @{ "killcounts.json" = "{""updated"":""$(& $iso $now)"",""killCounts"":{},""lootTracker"":{""NPC"":{""Kree\u0027arra"":{""kills"":3,""first"":1,""last"":2,""drops"":{""11826"":1}}},""EVENT"":{""Reward pool (\u0022x\u0022)"":{""kills"":1,""first"":1,""last"":2,""drops"":{}}}}}" }
Check "edge: odd names in kill history" { Reset-Data; [void](Update-PluginKills "2026-11-02T12:00:00.0000000Z"); $l = Parse ([IO.File]::ReadAllLines($KillHistoryFile)[-1]); $n = @($l.k.PSObject.Properties.Name)
  if ($n -notcontains "NPC|Kree'arra" -or $n -notcontains 'EVENT|Reward pool ("x")') { throw ($n -join ' / ') }; "Kree'arra, quotes ok" }

# ---------------------------------------------------------------- 2a. Grand Exchange offers on bank lines
$geFile = { param($ge) "{""updated"":""$(& $iso $now)"",""bank"":[[995,10,0]],""bankAt"":1793608110328,""inventory"":[],""equipment"":[],""ge"":$ge}" }
$geOffer = "{""slot"":2,""state"":""SELLING"",""id"":1391,""total"":68,""done"":0,""price"":7879,""spent"":0}"
$bankLines = { @([IO.File]::ReadAllLines("$DataDir\bank\history.jsonl") | Where-Object { $_.Trim() }) }
Set-PluginFiles @{ "containers.json" = (& $geFile "[]") }
Check "ge: no offers on the first line = empty list" { Reset-Data; [void](Update-Bank); $l = @(& $bankLines)[-1]; if ($l -notmatch ',"ge":\[\]\}$') { throw $l }; "ok" }
Set-PluginFiles @{ "containers.json" = (& $geFile "[$geOffer]") }
Check "ge: a new offer writes a line, ge as last field" { [void](Update-Bank); $l = @(& $bankLines); if ($l.Count -ne 2) { throw "$($l.Count) lines" }
  if (-not $l[-1].EndsWith(',"ge":[{"item":[1391,68],"done":0,"price":7879,"spent":0,"state":"SELLING"}]}')) { throw $l[-1] }; [void](Parse $l[-1]); "ok" }
Check "ge: same offer on the next Refresh writes nothing" { [void](Update-Bank); $n = @(& $bankLines).Count; if ($n -ne 2) { throw "$n lines" }; "still 2" }
Set-PluginFiles @{ "containers.json" = (& $geFile ($geOffer -replace '"done":0', '"done":5' -replace '"spent":0', '"spent":39395')) }
Check "ge: a part fill writes a line" { [void](Update-Bank); $n = @(& $bankLines).Count; if ($n -ne 3) { throw "$n lines" }; "3 lines" }
Set-PluginFiles @{ "containers.json" = (& $geFile "[]") }
Check "ge: a collected offer writes a line" { [void](Update-Bank); $n = @(& $bankLines).Count; if ($n -ne 4) { throw "$n lines" }; "4 lines" }
Set-PluginFiles @{ "containers.json" = "{""updated"":""$(& $iso $now)"",""bank"":[[995,10,0]],""bankAt"":1793608110328,""inventory"":[],""equipment"":[]}" }
Check "ge: old plugin file without ge writes nothing" { [void](Update-Bank); $l = @(& $bankLines); if ($l.Count -ne 4) { throw "$($l.Count) lines" }; "ok" }
Check "ge: old plugin file gives a line without ge" { Reset-Data; [void](Update-Bank); $l = @(& $bankLines)[-1]; if ($l -match '"ge"') { throw $l }; "ok" }

# ---------------------------------------------------------------- 2b. Drop log gaps (kills done without the plugin)
# Loot Tracker totals (killcounts.json) vs loot.jsonl: every type (monster, boss, clue, chest, pickpocket) must end up
# in the drop log exactly once, with the right drops
$lt = {   # killcounts.json with these totals: @{ "TYPE|name" = @(kills, last time, @{ id = qty }) }
  param($t, $src)
  $byType = @{}
  foreach ($k in $src.Keys) { $ty, $nm = $k -split '\|', 2; if (-not $byType[$ty]) { $byType[$ty] = [ordered]@{} }
    $byType[$ty][$nm] = [ordered]@{ kills = $src[$k][0]; first = 1; last = ([DateTimeOffset]$src[$k][1]).ToUnixTimeMilliseconds(); drops = $src[$k][2] } }
  "{""updated"":""$(& $iso $t)"",""killCounts"":{},""lootTracker"":$($byType | ConvertTo-Json -Compress -Depth 5)}" }
$ll = { param($t, $src, $type, $items) "{""t"":""$(& $iso $t)"",""source"":""$src"",""type"":""$type"",""value"":1,""items"":$(ConvertTo-Json -InputObject $items -Compress)}" }
$gaps = { if (Test-Path $LootGapFile) { @([IO.File]::ReadAllLines($LootGapFile) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
$gapOf = { param($key) @(& $gaps | Where-Object { "$($_.type)|$($_.source)" -eq $key }) }
$itemsOf = { param($g) (@($g.items | ForEach-Object { "$($_[0])x$($_[1])" }) | Sort-Object) -join "," }
$T1 = $now.AddHours(-5); $T2 = $now.AddHours(-4); $T3 = $now.AddHours(-3); $T4 = $now.AddHours(-2); $T5 = $now.AddHours(-1)
$tot1 = @{ "NPC|Tormented Demon" = @(10, $T1.AddMinutes(-9), @{ "1" = 5 }); "NPC|Vorkath" = @(5, $T1.AddMinutes(-9), @{ "3" = 1 })
  "EVENT|Clue Scroll (Hard)" = @(2, $T1.AddMinutes(-9), @{ "4" = 2 }); "EVENT|Barrows" = @(1, $T1.AddMinutes(-9), @{ "7" = 1 })
  "PICKPOCKET|Master Farmer" = @(4, $T1.AddMinutes(-9), @{ "5" = 4 }) }
Reset-Data
Set-PluginFiles @{ "killcounts.json" = (& $lt $T1 $tot1); "loot.jsonl" = (& $ll $T1.AddMinutes(-20) "Vorkath" "NPC" @(, @(3, 1, 1))) }
Check "gaps: first run, nothing missed -> no gap lines, totals saved" { $m = Update-PluginLootGaps; if (@(& $gaps).Count) { throw "gaps: $(@(& $gaps).Count)" }; if (-not (Test-Path $LootBaseFile)) { throw "no loot-base.json" }; $m }
# One hour later: some kills live (in loot.jsonl), some on the normal client (only in the totals)
$tot2 = @{ "NPC|Tormented Demon" = @(13, $T2.AddMinutes(-7), @{ "1" = 8; "2" = 1 }); "NPC|Vorkath" = @(7, $T2.AddMinutes(-30), @{ "3" = 3 })
  "EVENT|Clue Scroll (Hard)" = @(3, $T2.AddMinutes(-40), @{ "4" = 3 }); "EVENT|Barrows" = @(2, $T2.AddMinutes(-50), @{ "7" = 2 })
  "PICKPOCKET|Master Farmer" = @(9, $T2.AddMinutes(-5), @{ "5" = 9 }); "NPC|Zulrah" = @(1, $T2.AddMinutes(-15), @{ "6" = 1 }) }
Set-PluginFiles @{ "killcounts.json" = (& $lt $T2 $tot2); "loot.jsonl" = (@(
  (& $ll $T1.AddMinutes(-20) "Vorkath" "NPC" @(, @(3, 1, 1))),
  (& $ll $T1.AddMinutes(10) "Tormented Demon" "NPC" @(, @(1, 1, 1))),
  (& $ll $T1.AddMinutes(20) "Clue Scroll (Hard)" "EVENT" @(, @(4, 1, 1))),
  (& $ll $T1.AddMinutes(30) "Master Farmer" "PICKPOCKET" @(, @(5, 1, 1))),
  (& $ll $T1.AddMinutes(31) "Master Farmer" "PICKPOCKET" @(, @(5, 1, 1)))) -join "`n") }
Check "gaps: missed kills found for every type" { $m = Update-PluginLootGaps; $n = @(& $gaps).Count; if ($n -ne 5) { throw "$n gap lines: $((& $gaps | ForEach-Object { $_.source }) -join ', ')" }; $m }
Check "gaps: monster - 2 missed kills with their exact drops" { $g = @(& $gapOf "NPC|Tormented Demon"); if ($g.Count -ne 1 -or $g[0].kills -ne 2 -or (& $itemsOf $g[0]) -ne "1x2,2x1") { throw ($g | ConvertTo-Json -Compress) }; "2 kills: 1x2, 2x1" }
Check "gaps: boss (none live)" { $g = @(& $gapOf "NPC|Vorkath"); if ($g.Count -ne 1 -or $g[0].kills -ne 2 -or (& $itemsOf $g[0]) -ne "3x2") { throw ($g | ConvertTo-Json -Compress) }; "2 kills: 3x2" }
Check "gaps: chest" { $g = @(& $gapOf "EVENT|Barrows"); if ($g.Count -ne 1 -or $g[0].kills -ne 1 -or (& $itemsOf $g[0]) -ne "7x1") { throw ($g | ConvertTo-Json -Compress) }; "1 open: 7x1" }
Check "gaps: pickpocket (2 live, 3 missed)" { $g = @(& $gapOf "PICKPOCKET|Master Farmer"); if ($g.Count -ne 1 -or $g[0].kills -ne 3 -or (& $itemsOf $g[0]) -ne "5x3") { throw ($g | ConvertTo-Json -Compress) }; "3: 5x3" }
Check "gaps: new source (first kill without the plugin)" { $g = @(& $gapOf "NPC|Zulrah"); if ($g.Count -ne 1 -or $g[0].kills -ne 1 -or (& $itemsOf $g[0]) -ne "6x1") { throw ($g | ConvertTo-Json -Compress) }; "1 kill: 6x1" }
Check "gaps: clue all live -> no gap" { if ((& $gapOf "EVENT|Clue Scroll (Hard)").Count) { throw "gap written" }; "ok" }
Check "gaps: dated at the source's last kill" { $g = (& $gapOf "NPC|Tormented Demon")[0]; $want = $T2.AddMinutes(-7).ToString("yyyy-MM-ddTHH:mm"); if (-not $g.t.StartsWith($want)) { throw "$($g.t) want $want" }; $g.t }
Check "gaps: same totals again -> nothing new" { $m = Update-PluginLootGaps; if (@(& $gaps).Count -ne 5) { throw "now $(@(& $gaps).Count)" }; $m }
Check "gaps: reach /api/plugin with the live lines" { $j = Parse (Get-PluginJson); $g = @($j.drops | Where-Object { $_.gap }); if ($g.Count -ne 5 -or @($j.drops).Count -ne 10) { throw "$(@($j.drops).Count) drops, $($g.Count) gaps" }; "5 live + 5 gap lines" }
# A live kill saved to loot.jsonl a moment after the totals were: counted once, never as a gap
$f = Join-Path (Get-PluginDir) "loot.jsonl"; [IO.File]::AppendAllText($f, "`n" + (& $ll $T3.AddSeconds(-1) "Tormented Demon" "NPC" @(, @(1, 1, 1))), $Utf8)
$tot2["NPC|Tormented Demon"] = @(13, $T2.AddMinutes(-7), @{ "1" = 8; "2" = 1 })   # totals at T3 don't have it yet
[IO.File]::WriteAllText((Join-Path (Get-PluginDir) "killcounts.json"), (& $lt $T3 $tot2), $Utf8)
Check "gaps: live line ahead of the totals -> no gap" { [void](Update-PluginLootGaps); if (@(& $gaps).Count -ne 5) { throw "now $(@(& $gaps).Count)" }; "ok" }
$tot2["NPC|Tormented Demon"] = @(14, $T3.AddSeconds(-1), @{ "1" = 9; "2" = 1 })   # now the totals have it
[IO.File]::WriteAllText((Join-Path (Get-PluginDir) "killcounts.json"), (& $lt $T4 $tot2), $Utf8)
Check "gaps: ...and none when the totals catch up" { [void](Update-PluginLootGaps); if (@(& $gaps).Count -ne 5) { throw "now $(@(& $gaps | ForEach-Object { "$($_.source) $($_.kills)" }) -join ', ')" }; "ok" }
$tot2["NPC|Tormented Demon"] = @(2, $T5.AddMinutes(-1), @{ "1" = 2 })   # Loot Tracker reset by the player
[IO.File]::WriteAllText((Join-Path (Get-PluginDir) "killcounts.json"), (& $lt $T5 $tot2), $Utf8)
Check "gaps: Loot Tracker reset -> no gap, counting restarts" { [void](Update-PluginLootGaps); if (@(& $gaps).Count -ne 5) { throw "now $(@(& $gaps).Count)" }; "ok" }
$tot2["NPC|Tormented Demon"] = @(5, $now.AddMinutes(-1), @{ "1" = 4; "9" = 1 })
[IO.File]::WriteAllText((Join-Path (Get-PluginDir) "killcounts.json"), (& $lt $now $tot2), $Utf8)
Check "gaps: after a reset, missed kills found again" { [void](Update-PluginLootGaps); $g = @(& $gapOf "NPC|Tormented Demon"); if ($g.Count -ne 2 -or $g[1].kills -ne 3 -or (& $itemsOf $g[1]) -ne "1x2,9x1") { throw ($g[-1] | ConvertTo-Json -Compress) }; "3 kills: 1x2, 9x1" }
# First run with older kill history: kills missed since the drop log began (drops unknown then)
Reset-Data
[IO.File]::WriteAllText($KillHistoryFile, "{""t"":""$(& $iso $T1)"",""k"":{""NPC|Tormented Demon"":10,""EVENT|Barrows"":1}}`n{""t"":""$(& $iso $T2)"",""k"":{""NPC|Tormented Demon"":12,""EVENT|Barrows"":1}}`n", $Utf8)
Set-PluginFiles @{ "killcounts.json" = (& $lt $T3 @{ "NPC|Tormented Demon" = @(15, $T3.AddMinutes(-2), @{ "1" = 9 }); "EVENT|Barrows" = @(1, $T1, @{ "7" = 1 }) })
  "loot.jsonl" = ((& $ll $T1.AddMinutes(-30) "Barrows" "EVENT" @(, @(7, 1, 1))), (& $ll $T1.AddMinutes(5) "Tormented Demon" "NPC" @(, @(1, 1, 1)))) -join "`n" }
Check "gaps: first run back-fills from kill history" { [void](Update-PluginLootGaps); $g = @(& $gapOf "NPC|Tormented Demon"); $k = @($g | ForEach-Object { $_.kills }) -join "+"
  if ($k -ne "1+3" -or $null -ne $g[0].items) { throw "kills $k" }; "1 (T1-T2) + 3 (T2-T3), drops unknown" }
Check "gaps: back-fill then counts drops normally" { $tt = @{ "NPC|Tormented Demon" = @(16, $T4.AddMinutes(-2), @{ "1" = 10; "8" = 1 }); "EVENT|Barrows" = @(1, $T1, @{ "7" = 1 }) }
  [IO.File]::WriteAllText((Join-Path (Get-PluginDir) "killcounts.json"), (& $lt $T4 $tt), $Utf8); [void](Update-PluginLootGaps)
  $g = @(& $gapOf "NPC|Tormented Demon")[-1]; if ($g.kills -ne 1 -or (& $itemsOf $g) -ne "1x1,8x1") { throw ($g | ConvertTo-Json -Compress) }; "1 kill: 1x1, 8x1" }
# A collection log item dropped without the plugin counts into the log once
Reset-Data
Set-PluginFiles @{ "clog.json" = "{""updated"":""$(& $iso $T1)"",""items"":{""4151"":1},""newByName"":{}}"; "killcounts.json" = (& $lt $T1 @{ "NPC|Abyssal demon" = @(10, $T1.AddMinutes(-5), @{ "4151" = 1; "592" = 10 }) }) }
[void](Update-PluginLootGaps); [void](Update-PluginClog)
[IO.File]::WriteAllText((Join-Path (Get-PluginDir) "killcounts.json"), (& $lt $T2 @{ "NPC|Abyssal demon" = @(12, $T2.AddMinutes(-5), @{ "4151" = 3; "592" = 12 }) }), $Utf8)
Check "gaps: log item from a missed kill counts in the collection log" { [void](Update-PluginLootGaps); [void](Update-PluginClog); $p = Parse ([IO.File]::ReadAllLines("$DataDir\clog\history.jsonl")[-1]); $q = $p.items.'4151'[0]; if ($q -ne 3) { throw "whip $q, want 3" }; "whip 1 -> 3" }
Check "gaps: ...only once" { [void](Update-PluginLootGaps); [void](Update-PluginClog); $p = Parse ([IO.File]::ReadAllLines("$DataDir\clog\history.jsonl")[-1]); $q = $p.items.'4151'[0]; if ($q -ne 3) { throw "whip $q" }; "still 3" }
Check "gaps: real plugin files run clean" { Reset-Data; Copy-Item "$RealPlugin\*" (Get-PluginDir) -Force; $m = Update-PluginLootGaps; [void](Parse (Get-PluginJson)); $m }

# ---------------------------------------------------------------- 3. folder name: plugin (Java safeName) vs dashboard (Get-PluginDir)
foreach ($c in @(@("Player One", "player_one"), @("Iron$([char]160)Man", "iron_man"), @("Iron Man", "iron_man"), @("a  .b", "a_b"), @("x-y_z", "x-y_z"), @("$([char]160)Zezima ", "zezima"))) {
  $Player = $c[0]; $got = if ($Impl -eq "app") { Split-Path (& $Exe --plugin-dir $c[0]) -Leaf } else { Split-Path (Get-PluginDir) -Leaf }
  Check "folder: '$($c[0])' -> $($c[1])" { if ($got -ne $c[1]) { throw "got $got" }; "ok" }
}
$Player = $RealPlayer

if ($Impl -eq "app" -and (Test-Path "$Work\tape\missing.txt")) { $script:WebCalls = @([IO.File]::ReadAllLines("$Work\tape\missing.txt")).Count }
"Implementation: $Impl"
$results | Format-Table -AutoSize -Wrap ok, test, note
"{0} passed, {1} failed; downloads attempted (all stubbed): {2}" -f @($results | Where-Object ok).Count, @($results | Where-Object { -not $_.ok }).Count, $script:WebCalls
Remove-Item $Work -Recurse -Force
