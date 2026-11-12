# Export / Import between your own devices (e.g. a Windows PC and a Mac), so both dashboards hold the same history.
# Export writes one file to your Downloads folder; move it to the other device any way you like (AirDrop, USB stick,
# email to yourself) and Import it there. Nothing goes over the network. Dot-sourced by server.ps1 after plugin.ps1.
#
# Import MERGES: every history keeps the snapshots of both devices (the same snapshot twice = once), sorted by time.
#   history.jsonl, bank\history.jsonl, bank\prices-saves.jsonl, plugin\kills-history.jsonl   one line per time "t"
#   progress\history.jsonl   + latest.json when the other device's newest progress is newer
#   clog\history.jsonl       from the other device's first line on, each line holds every item either device had by
#                            then (highest count, earliest date); the last line keeps THIS device's lootT/gapN markers
#   bank\history.jsonl       a line whose bank was seen before an earlier line's bank (the device hadn't opened the
#                            bank since) gets that newer bank, so the value graph doesn't dip back to an old bank
#   loot                     the other device's loot.jsonl -> data\plugin\loot-other.jsonl (the plugin's own file is
#                            never written). Drop log gaps (loot-gaps.jsonl) stay per device: with RuneLite's synced
#                            Loot Tracker, kills made on the other device look like "played without the plugin" here,
#                            so a gap is reduced by the other device's real drops in its window (Get-SyncDrops).
#                            The other device's gaps from before this device's drop log began -> gaps-other.jsonl.
# Settings (player name, Wise Old Man answer), prices and pictures stay per device.
#
# The file: line 1 {"osrsDashboardSync":1,"player","device":{"id","name"},"exported","seen":{..}}, then for each part
# a line {"section":"<name>"} followed by that file's lines as they are (every part is JSON lines; no line starts
# with {"section").
#
# data\sync\state.json  {"id","name","seen":{"progress","killcounts","containers","bankAt"},"exported","imported"}
#   seen = the newest plugin files ("updated" times, bank time) of any device merged in. A Refresh skips a plugin file
#   older than that (RuneLite hasn't run on this device since), so old quests / bank / kill totals from here never
#   become the newest snapshot. Once RuneLite runs here again, its files are newer and count as usual.
# data\sync\backup-<time>\  the files as they were before an import (the newest 3 are kept)

$SyncDir       = Join-Path $DataDir "sync"
$SyncStateFile = Join-Path $SyncDir "state.json"
$LootOtherFile = Join-Path $PluginDataDir "loot-other.jsonl"
$GapsOtherFile = Join-Path $PluginDataDir "gaps-other.jsonl"
$SyncVersion   = 1
# Part name in the file -> path under data\
$SyncParts = [ordered]@{
  history    = @("history.jsonl")
  bank       = @("bank", "history.jsonl")
  bankPrices = @("bank", "prices-saves.jsonl")
  progress   = @("progress", "history.jsonl")
  clog       = @("clog", "history.jsonl")
  kills      = @("plugin", "kills-history.jsonl")
}
function Get-SyncPartFile([string]$part) {
  $p = $DataDir; foreach ($s in $SyncParts[$part]) { $p = Join-Path $p $s }; return $p
}

# ---- small helpers ----
# ConvertFrom-Json that keeps times as the text they are (PowerShell 7 would turn them into dates in local format)
$SyncDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")
function ConvertFrom-SyncJson([string]$text) { if ($SyncDateKind) { $text | ConvertFrom-Json -DateKind String } else { $text | ConvertFrom-Json } }
$SyncCulture = [Globalization.CultureInfo]::InvariantCulture
function ConvertTo-SyncTime([string]$s) {
  if (-not $s) { return [datetime]::MinValue }
  try { return [DateTimeOffset]::Parse($s, $SyncCulture).UtcDateTime } catch { return [datetime]::MinValue }
}
function Get-SyncLineT([string]$l) { if ($l -match '^\{"t":"([^"]*)"') { return $Matches[1] } return $null }
# Non-blank lines of a file, trimmed
function Read-SyncLines([string]$file) {
  $out = New-Object System.Collections.Generic.List[string]
  if (Test-Path $file) { foreach ($l in [IO.File]::ReadAllLines($file, $Utf8)) { $t = $l.Trim(); if ($t) { $out.Add($t) } } }
  return , $out
}
function Write-SyncLines([string]$file, $lines) {
  $dir = Split-Path $file -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
  $tmp = "$file.tmp"
  [IO.File]::WriteAllText($tmp, $(if ($lines.Count) { [string]::Join("`n", [string[]]$lines) + "`n" } else { "" }), $Utf8)
  Move-Item -Force $tmp $file
}
# Lines sorted by time, oldest first; lines with the same time keep their order (a stable sort)
function Sort-SyncLines($lines, [scriptblock]$timeOf) {
  $n = $lines.Count
  $keys = New-Object 'decimal[]' $n
  $arr = New-Object 'string[]' $n
  for ($i = 0; $i -lt $n; $i++) { $arr[$i] = $lines[$i]; $keys[$i] = [decimal](& $timeOf $lines[$i]).Ticks * 1000000 + $i }
  [Array]::Sort($keys, $arr)
  $out = New-Object System.Collections.Generic.List[string]
  $out.AddRange($arr)
  return , $out
}
$SyncByT = { param($l) ConvertTo-SyncTime (Get-SyncLineT $l) }

# ---- this device: data\sync\state.json ----
function Get-SyncState {
  $s = $null
  if (Test-Path $SyncStateFile) { try { $s = ConvertFrom-SyncJson ([IO.File]::ReadAllText($SyncStateFile, $Utf8)) } catch { $s = $null } }
  $st = [ordered]@{
    id = if ($s.id) { [string]$s.id } else { $null }
    name = if ($s.name) { [string]$s.name } else { $null }
    seen = [ordered]@{
      progress = if ($s.seen.progress) { [string]$s.seen.progress } else { $null }
      killcounts = if ($s.seen.killcounts) { [string]$s.seen.killcounts } else { $null }
      containers = if ($s.seen.containers) { [string]$s.seen.containers } else { $null }
      bankAt = [long]$s.seen.bankAt
    }
    exported = if ($s.exported) { [string]$s.exported } else { $null }
    imported = if ($s.imported) { [ordered]@{ from = [string]$s.imported.from; name = [string]$s.imported.name; exported = [string]$s.imported.exported; t = [string]$s.imported.t } } else { $null }
    # Automatic sync (see "Automatic sync" below)
    folder = if ($s.folder) { [string]$s.folder } else { $null }
    autoSeen = [ordered]@{}
    autoExported = if ($s.autoExported) { [string]$s.autoExported } else { $null }
    autoError = if ($s.autoError) { [string]$s.autoError } else { $null }
  }
  if ($s.autoSeen) { foreach ($p in $s.autoSeen.PSObject.Properties) { $st.autoSeen[$p.Name] = [string]$p.Value } }
  if (-not $st.id) {
    $st.id = -join (1..16 | ForEach-Object { "{0:x}" -f (Get-Random -Maximum 16) })
    $st.name = Get-SyncDeviceName
    Save-SyncState $st
  }
  return $st
}
function Save-SyncState($st) {
  if (-not (Test-Path $SyncDir)) { New-Item -ItemType Directory $SyncDir | Out-Null }
  [IO.File]::WriteAllText($SyncStateFile, ($st | ConvertTo-Json -Compress -Depth 4), $Utf8)
}
function Get-SyncDeviceName {
  $n = [Environment]::MachineName
  if (-not $n) { $n = "This device" }
  return $n
}
# The newer of two ISO times (either may be empty)
function Get-SyncNewer([string]$a, [string]$b) {
  if (-not $a) { return $b }; if (-not $b) { return $a }
  if ((ConvertTo-SyncTime $b) -gt (ConvertTo-SyncTime $a)) { return $b } else { return $a }
}
# For the Refresh steps: is this plugin file ("progress" / "killcounts" / "containers") older than one merged in from
# another device? Then it is skipped (see the top of this file).
function Test-SyncStale([string]$kind, $updated) {
  if (-not (Test-Path $SyncStateFile)) { return $false }
  $seen = (Get-SyncState).seen.$kind
  if (-not $seen -or -not $updated) { return $false }
  $u = if ($updated -is [datetime]) { $updated.ToUniversalTime() } else { ConvertTo-SyncTime ([string]$updated) }
  if ($u -eq [datetime]::MinValue) { return $false }   # no readable time: not skipped
  return $u -lt (ConvertTo-SyncTime $seen)
}
function Get-SyncSeenBankAt { if (Test-Path $SyncStateFile) { (Get-SyncState).seen.bankAt } else { 0L } }

# The newest plugin files this device knows of: its own (now) or merged in earlier
function Get-SyncSeenNow($st) {
  $seen = [ordered]@{ progress = $st.seen.progress; killcounts = $st.seen.killcounts; containers = $st.seen.containers; bankAt = [long]$st.seen.bankAt }
  $dir = Get-PluginDir
  foreach ($k in "progress", "killcounts", "containers") {
    $f = Join-Path $dir "$k.json"
    if (-not (Test-Path $f)) { continue }
    $o = try { ConvertFrom-SyncJson ([IO.File]::ReadAllText($f, $Utf8)) } catch { $null }
    if (-not $o) { continue }
    $seen[$k] = Get-SyncNewer $seen[$k] ([string]$o.updated)
    if ($k -eq "containers" -and [long]$o.bankAt -gt $seen.bankAt) { $seen.bankAt = [long]$o.bankAt }
  }
  return $seen
}

function Get-SyncStatusJson {
  $st = Get-SyncState
  $folder = Get-SyncAutoFolder $st
  $others = @(if ($folder) { foreach ($o in (Get-SyncAutoFiles $folder $st.id)) {
    $m = $st.autoSeen.Contains($o.id) -and (ConvertTo-SyncTime $st.autoSeen[$o.id]) -ge (ConvertTo-SyncTime $o.exported)
    [ordered]@{ name = $o.name; exported = $o.exported; merged = $m }
  } })
  return ([ordered]@{ device = $st.name; exported = $st.exported; imported = $st.imported; folder = $folder; folderSet = $st.folder
    autoExported = $st.autoExported; autoError = $st.autoError; others = $others } | ConvertTo-Json -Compress -Depth 4)
}

# ---- RuneLite's current files from the other device ----
# The page shows some sections straight from the plugin's files (Kills & loot from killcounts.json, GE offers and
# storage from containers.json, ...). A device where RuneLite doesn't run would show old ones, so they travel in
# the sync file too; data\plugin\other\<file> keeps the other device's copy, and the page gets whichever of the two
# has the newer "updated" time.
$SyncPluginFiles = @("progress.json", "killcounts.json", "clog.json", "containers.json")
$SyncOtherPluginDir = Join-Path $PluginDataDir "other"
function Get-SyncWholeJson([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  $t = ([IO.File]::ReadAllText($path, $Utf8).Trim()) -replace "[\r\n]", ""
  if ($t.StartsWith("{") -and $t.EndsWith("}")) { return $t } else { return $null }
}
function Get-SyncUpdated([string]$text) { if ($text -match '"updated":"([^"]*)"') { $Matches[1] } else { "" } }
# The newer of this device's plugin file and the other device's copy: @{ text; other } or $null
function Get-SyncNewestPluginFile([string]$name) {
  $own = Get-SyncWholeJson (Join-Path (Get-PluginDir) $name)
  $other = Get-SyncWholeJson (Join-Path $SyncOtherPluginDir $name)
  if ($own -and $other) {
    if ((ConvertTo-SyncTime (Get-SyncUpdated $other)) -gt (ConvertTo-SyncTime (Get-SyncUpdated $own))) { return @{ text = $other; other = $true } }
    return @{ text = $own; other = $false }
  }
  if ($own) { return @{ text = $own; other = $false } }
  if ($other) { return @{ text = $other; other = $true } }
  return $null
}

# ---- Export ----
# The export file's text: @(text, counts per part)
$SyncEndLine = '{"section":"end"}'
function Get-SyncExportText($st, [string]$now) {
  $head = [ordered]@{ osrsDashboardSync = $SyncVersion; player = $Player; device = [ordered]@{ id = $st.id; name = $st.name }; exported = $now; seen = (Get-SyncSeenNow $st) }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append(($head | ConvertTo-Json -Compress -Depth 4)).Append("`n")
  $counts = [ordered]@{}
  $add = {
    param($name, $file)
    [void]$sb.Append("{""section"":""$name""}`n")
    $n = 0
    foreach ($l in (Read-SyncLines $file)) { if (-not $l.StartsWith('{"section"')) { [void]$sb.Append($l).Append("`n"); $n++ } }
    $counts[$name] = $n
  }
  foreach ($part in $SyncParts.Keys) { & $add $part (Get-SyncPartFile $part) }
  & $add "loot" (Join-Path (Get-PluginDir) "loot.jsonl")   # this device's own drops only (not loot-other)
  & $add "gaps" $LootGapFile
  # RuneLite's current files (Kills & loot, GE offers, storage...): this device's own or, when newer, the ones the
  # other device sent. One line each: {"file":"killcounts.json","data":<the file>}
  [void]$sb.Append('{"section":"pluginFiles"}').Append("`n")
  foreach ($f in $SyncPluginFiles) {
    $n = Get-SyncNewestPluginFile $f
    if ($n) { [void]$sb.Append("{""file"":""$f"",""data"":$($n.text)}").Append("`n") }
  }
  # Last line: the file is whole (an automatic import skips a file the cloud drive hasn't finished copying)
  [void]$sb.Append($SyncEndLine).Append("`n")
  return @($sb.ToString(), $counts)
}
# POST /api/export -> @(status, JSON {"message","path"} | {"error"})
function Export-Sync {
  if (-not $Player) { return @(400, "{""error"":""Set up your player name first.""}") }
  $st = Get-SyncState
  $now = (Get-Date).ToUniversalTime().ToString("o")
  $text, $counts = Get-SyncExportText $st $now
  $dir = if ($SyncExportDir) { $SyncExportDir } else { Join-Path $HOME "Downloads" }   # tests set $SyncExportDir
  if (-not (Test-Path $dir)) { $dir = $HOME }
  $dev = ($st.name -replace '[^A-Za-z0-9 _-]', '').Trim()
  $file = Join-Path $dir "OSRS Dashboard sync - $Player - $dev - $((Get-Date).ToString('yyyy-MM-dd HHmm')).osrssync"
  [IO.File]::WriteAllText($file, $text, $Utf8)
  $st.exported = $now
  Save-SyncState $st
  Write-Host "Exported for another device: $file"
  $msg = "Saved to $file ($($counts.history) hiscores snapshots, $($counts.bank) bank saves, $($counts.loot) drops)."
  return @(200, ([ordered]@{ message = $msg; path = $file } | ConvertTo-Json -Compress))
}

# ---- Import ----
# Merges lines keyed by "t" into this device's lines: @{ lines; added; from = index of the first line from the other
# device in the result (-1 = none added) }
function Merge-SyncByT($own, $other) {
  $keys = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($l in $own) { $k = Get-SyncLineT $l; [void]$keys.Add($(if ($null -ne $k) { $k } else { $l })) }
  $all = New-Object System.Collections.Generic.List[string]
  $all.AddRange([string[]]@($own))
  $new = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($l in $other) {
    $k = Get-SyncLineT $l; if ($null -eq $k) { continue }   # every part's lines start with {"t":
    if ($keys.Add($k)) { $all.Add($l); [void]$new.Add($l) }
  }
  if (-not $new.Count) { return @{ lines = $own; added = 0; from = -1 } }
  $sorted = Sort-SyncLines $all $SyncByT
  $from = -1; for ($i = 0; $i -lt $sorted.Count; $i++) { if ($new.Contains($sorted[$i])) { $from = $i; break } }
  return @{ lines = $sorted; added = $new.Count; from = $from }
}

# Bank lines: "saved" is when the bank was last seen open (local time, "HH:mm:ss, d MMM yyyy", "before ..." when not
# known exactly). From the first merged line on, a line whose bank is older than an earlier line's gets that bank.
function Get-SyncBankSeen([string]$line) {
  if ($line -notmatch '"saved":"((?:[^"\\]|\\.)*)"') { return $null }
  $s = $Matches[1] -replace '^before ', ''
  $t = [datetime]::MinValue
  if ([datetime]::TryParseExact($s, "HH:mm:ss, d MMM yyyy", $SyncCulture, [Globalization.DateTimeStyles]::None, [ref]$t)) { return $t }
  return $null
}
$SyncBankItems = '"items":\[(?:\[-?\d+,-?\d+\],?)*\]'
function Repair-SyncBank($r) {
  if ($r.from -lt 0) { return 0 }
  $lines = $r.lines; $best = $null; $fixed = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $seen = Get-SyncBankSeen $lines[$i]
    if ($null -eq $seen) { continue }
    if ($best -and $seen -lt $best.seen -and $i -ge $r.from) {
      $m = [regex]::Match($lines[$i], $SyncBankItems)
      if ($m.Success) {
        $l = $lines[$i].Substring(0, $m.Index) + $best.items + $lines[$i].Substring($m.Index + $m.Length)
        $lines[$i] = [regex]::Replace($l, '"saved":"(?:[^"\\]|\\.)*"', { param($x) $best.saved }, 1)
        $fixed++
      }
      continue
    }
    if (-not $best -or $seen -ge $best.seen) {
      $best = @{ seen = $seen; items = [regex]::Match($lines[$i], $SyncBankItems).Value; saved = [regex]::Match($lines[$i], '"saved":"(?:[^"\\]|\\.)*"').Value }
      if (-not $best.items) { $best = $null }
    }
  }
  return $fixed
}

# Collection log lines from the first merged line on: every item either device had by then (highest count, earliest
# date). The last line gets this device's markers (lootT: last drop counted from its loot.jsonl, gapN: gap lines
# counted), since only this device's files are read at its next Refresh.
function Repair-SyncClog($r, $own) {
  if ($r.from -lt 0) { return }
  $lines = $r.lines
  $run = [ordered]@{}; $avail = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $o = try { ConvertFrom-SyncJson $lines[$i] } catch { $null }
    if (-not $o) { continue }
    $own_ = [ordered]@{}
    foreach ($p in $o.items.PSObject.Properties) { $own_[$p.Name] = @([long]@($p.Value)[0], [string]@($p.Value)[1]) }
    $same = $true
    foreach ($id in $own_.Keys) {
      $c = $own_[$id][0]; $d = $own_[$id][1]
      if ($run.Contains($id)) {
        $was = $run[$id]
        $run[$id] = @([Math]::Max($was[0], $c), $(if ($d -and ($was[1] -eq "" -or [string]::CompareOrdinal($d, $was[1]) -lt 0)) { $d } else { $was[1] }))
      } else { $run[$id] = @($c, $d) }
    }
    if ([long]$o.available -gt $avail) { $avail = [long]$o.available }
    if ($i -lt $r.from) { continue }
    if ($run.Count -ne $own_.Count) { $same = $false }
    else { foreach ($id in $run.Keys) { if (-not $own_.Contains($id) -or $own_[$id][0] -ne $run[$id][0] -or $own_[$id][1] -ne $run[$id][1]) { $same = $false; break } } }
    if ($same) { continue }
    $m = [regex]::Match($lines[$i], '^(.*?)"items":\{.*\}\}$')
    if (-not $m.Success) { continue }
    $head = $m.Groups[1].Value -replace '"total":\d+', "`"total`":$($run.Count)" -replace '"available":\d+', "`"available`":$avail"
    $items = [string]::Join(",", [string[]]@(foreach ($id in $run.Keys) { "`"$id`":[$($run[$id][0]),$(ConvertTo-Json $run[$id][1])]" }))
    $lines[$i] = $head + '"items":{' + $items + '}}'
  }
  # Markers on the last line: this device's own (none yet: start from its own clog.json / gap 0)
  $last = $lines.Count - 1
  $ownLast = if ($own.Count) { $own[$own.Count - 1] } else { $null }
  if ($ownLast -and $lines[$last] -eq $ownLast) { return }
  $lootT = if ($ownLast -and $ownLast -match '"lootT":(null|"[^"]*")') { $Matches[1] } else { "null" }
  $gapN = if ($ownLast -and $ownLast -match '"gapN":(null|-?\d+)') { $Matches[1] } else { "0" }
  $lines[$last] = $lines[$last] -replace '"lootT":(null|"[^"]*")', "`"lootT`":$lootT" -replace '"gapN":(null|-?\d+)', "`"gapN`":$gapN"
}

# POST /api/import (body = an export file) -> @(status, JSON {"message"} | {"error"})
function Import-Sync([string]$text) {
  if (-not $Player) { return @(400, "{""error"":""Set up your player name first.""}") }
  $lines = $text.Split([char[]]"`r`n", [StringSplitOptions]::RemoveEmptyEntries)
  $head = if ($lines.Count) { try { ConvertFrom-SyncJson $lines[0] } catch { $null } } else { $null }
  if (-not $head -or $head.osrsDashboardSync -ne $SyncVersion) { return @(400, "{""error"":""This isn't an OSRS Dashboard sync file (made with Export on another device).""}") }
  $norm = { param($n) (([string]$n -replace [char]160, ' ').Trim().ToLowerInvariant() -replace '[^a-z0-9_-]+', '_') }
  if ((& $norm $head.player) -ne (& $norm $Player)) {
    return @(409, "{""error"":$(ConvertTo-JsonString "This file is for $($head.player), but this dashboard is set up for $Player.")}")
  }
  $st = Get-SyncState
  if ([string]$head.device.id -eq $st.id) { return @(409, "{""error"":""This file was exported on this device. Import it on your other device.""}") }
  $parts = @{}; $cur = $null
  for ($i = 1; $i -lt $lines.Count; $i++) {
    $l = $lines[$i].Trim()
    if (-not $l) { continue }
    if ($l -match '^\{"section":"([A-Za-z]+)"\}$') { $cur = $Matches[1]; $parts[$cur] = New-Object System.Collections.Generic.List[string]; continue }
    if ($cur -and $l.StartsWith("{") -and $l.EndsWith("}")) { $parts[$cur].Add($l) }
  }
  $get = { param($n) if ($parts.ContainsKey($n)) { , $parts[$n] } else { , (New-Object System.Collections.Generic.List[string]) } }

  # The files as they are now, in case something needs undoing
  $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
  $backup = Join-Path $SyncDir "backup-$stamp"
  New-Item -ItemType Directory $backup -Force | Out-Null
  $targets = @($SyncParts.Keys | ForEach-Object { Get-SyncPartFile $_ }) + @((Join-Path (Join-Path $DataDir "progress") "latest.json"), $LootOtherFile, $GapsOtherFile)
  foreach ($f in $targets) {
    if (-not (Test-Path $f)) { continue }
    $rel = $f.Substring($DataDir.Length).TrimStart('\', '/')
    $dst = Join-Path $backup $rel
    New-Item -ItemType Directory (Split-Path $dst -Parent) -Force | Out-Null
    Copy-Item $f $dst
  }
  @(Get-ChildItem $SyncDir -Directory -Filter "backup-*" | Sort-Object Name -Descending | Select-Object -Skip 3) | ForEach-Object { Remove-Item $_.FullName -Recurse -Force }

  $added = [ordered]@{}
  # Snapshots by time
  foreach ($part in "history", "bank", "bankPrices") {
    $file = Get-SyncPartFile $part
    $own = Read-SyncLines $file
    $r = Merge-SyncByT $own (& $get $part)
    $added[$part] = $r.added
    if ($part -eq "bank") { $added["bankFixed"] = Repair-SyncBank $r }
    if ($r.added) { Write-SyncLines $file $r.lines }
  }
  # Kill totals: by time, then a line equal to the one before it is dropped
  $file = Get-SyncPartFile "kills"
  $r = Merge-SyncByT (Read-SyncLines $file) (& $get "kills")
  $added["kills"] = $r.added
  if ($r.added) {
    $out = New-Object System.Collections.Generic.List[string]; $prevK = $null
    foreach ($l in $r.lines) { $k = $l -replace '^\{"t":"[^"]*",', ''; if ($k -ne $prevK) { $out.Add($l) }; $prevK = $k }
    Write-SyncLines $file $out
  }
  # Collection log
  $file = Get-SyncPartFile "clog"
  $own = Read-SyncLines $file
  $r = Merge-SyncByT $own (& $get "clog")
  $added["clog"] = $r.added
  if ($r.added) { Repair-SyncClog $r $own; Write-SyncLines $file $r.lines }
  # Quests / diaries / combat achievements: lines are whole states, dated by the plugin's "timestamp"
  $file = Get-SyncPartFile "progress"
  $own = Read-SyncLines $file
  $have = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@($own))
  $all = New-Object System.Collections.Generic.List[string]; $all.AddRange([string[]]@($own)); $n = 0
  foreach ($l in (& $get "progress")) { if ($have.Add($l)) { $all.Add($l); $n++ } }
  $added["progress"] = $n
  if ($n) {
    $tsOf = { param($l) if ($l -match '"timestamp":"([^"]*)"') { ConvertTo-SyncTime $Matches[1] } else { [datetime]::MinValue } }
    $sorted = Sort-SyncLines $all $tsOf
    Write-SyncLines $file $sorted
    $latestFile = Join-Path (Join-Path $DataDir "progress") "latest.json"
    $newest = $sorted[$sorted.Count - 1]
    $cur = if (Test-Path $latestFile) { [IO.File]::ReadAllText($latestFile, $Utf8) } else { "" }
    if ((& $tsOf $newest) -gt (& $tsOf $cur)) { [IO.File]::WriteAllText($latestFile, $newest, $Utf8) }
  }
  # Drops: the other device's own drop log, next to this device's (never written into the plugin's file)
  $ownLoot = Read-SyncLines (Join-Path (Get-PluginDir) "loot.jsonl")
  $ownSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@($ownLoot))
  $lo = Read-SyncLines $LootOtherFile
  $loSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@($lo)); $n = 0
  foreach ($l in (& $get "loot")) { if ($l.StartsWith('{"t":"') -and -not $ownSet.Contains($l) -and $loSet.Add($l)) { $lo.Add($l); $n++ } }
  $added["loot"] = $n
  if ($n) { Write-SyncLines $LootOtherFile (Sort-SyncLines $lo $SyncByT) }
  # The other device's gaps from before this device's drop log began (later ones this device finds itself)
  $since = [datetime]::MaxValue
  foreach ($l in $ownLoot) { $t = ConvertTo-SyncTime (Get-SyncLineT $l); if ($t -ne [datetime]::MinValue -and $t -lt $since) { $since = $t } }
  $go = Read-SyncLines $GapsOtherFile
  $goSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@($go)); $n = 0
  foreach ($l in (& $get "gaps")) { if ($l.StartsWith('{"t":"') -and (ConvertTo-SyncTime (Get-SyncLineT $l)) -le $since -and $goSet.Add($l)) { $go.Add($l); $n++ } }
  $added["gaps"] = $n
  if ($n) { Write-SyncLines $GapsOtherFile (Sort-SyncLines $go $SyncByT) }

  # RuneLite's current files from the other device, each kept when newer than the copy already here
  $n = 0
  if (-not (Test-Path $SyncOtherPluginDir)) { New-Item -ItemType Directory $SyncOtherPluginDir -Force | Out-Null }
  foreach ($l in (& $get "pluginFiles")) {
    if ($l -notmatch '^\{"file":"([a-z]+\.json)","data":(\{.*\})\}$') { continue }
    $name = $Matches[1]; $text = $Matches[2]
    if ($SyncPluginFiles -notcontains $name) { continue }
    try { [void]($text | ConvertFrom-Json) } catch { continue }
    $dst = Join-Path $SyncOtherPluginDir $name
    $cur = Get-SyncWholeJson $dst
    if ((ConvertTo-SyncTime (Get-SyncUpdated $text)) -gt (ConvertTo-SyncTime $(if ($cur) { Get-SyncUpdated $cur } else { "" }))) {
      Write-SyncLines $dst @($text); $n++
    }
  }
  $added["pluginFiles"] = $n

  # Newest plugin files known (see Test-SyncStale) and where this import came from
  foreach ($k in "progress", "killcounts", "containers") { $st.seen[$k] = Get-SyncNewer $st.seen[$k] ([string]$head.seen.$k) }
  if ([long]$head.seen.bankAt -gt $st.seen.bankAt) { $st.seen.bankAt = [long]$head.seen.bankAt }
  $st.imported = [ordered]@{ from = [string]$head.device.id; name = [string]$head.device.name; exported = [string]$head.exported; t = (Get-Date).ToUniversalTime().ToString("o") }
  Save-SyncState $st

  $total = 0; foreach ($k in $added.Keys) { if ($k -ne "bankFixed") { $total += $added[$k] } }
  $what = @()
  if ($added.history) { $what += "$($added.history) hiscores snapshots" }
  if ($added.bank) { $what += "$($added.bank) bank saves" }
  if ($added.progress) { $what += "$($added.progress) quest/diary updates" }
  if ($added.clog) { $what += "$($added.clog) collection log updates" }
  if ($added.loot) { $what += "$($added.loot) drops" }
  if ($added.kills) { $what += "$($added.kills) kill count updates" }
  if ($added.pluginFiles) { $what += "$($added.pluginFiles) RuneLite files" }
  $from = [string]$head.device.name
  $msg = if ($total) { "Merged from ${from}: " + ($what -join ", ") + "." } else { "Already up to date with $from." }
  Write-Host "Import from ${from}: $(($added.Keys | ForEach-Object { "$_ $($added[$_])" }) -join ', ') (backup: $backup)"
  return @(200, ([ordered]@{ message = $msg } | ConvertTo-Json -Compress))
}

# ---- Automatic sync through a shared folder ----
# Google Drive (or a folder picked by hand) keeps one file per device in "OSRS Dashboard Sync":
#   "<player> - <device name> (<device id>).osrssync", the same file Export makes, rewritten after every Refresh.
# Before a Refresh (and when the page opens) the other devices' files there are merged in, each only when it is
# newer than the one merged last time (autoSeen) and whole (ends with {"section":"end"}). Nothing else goes online:
# the cloud drive's own app copies the folder between the computers.
$SyncAutoDirName = "OSRS Dashboard Sync"
# Google Drive for desktop's "My Drive" folder on this computer
function Get-SyncGoogleDrive {
  if ($IsMacOS) {
    $cs = Join-Path $HOME "Library/CloudStorage"
    if (-not (Test-Path $cs)) { return $null }
    foreach ($a in @(Get-ChildItem $cs -Directory -Filter "GoogleDrive-*" | Sort-Object Name)) {
      $md = Join-Path $a.FullName "My Drive"
      if (Test-Path $md -PathType Container) { return $md }
      $sub = @(Get-ChildItem $a.FullName -Directory | Where-Object { -not $_.Name.StartsWith(".") -and $_.Name -ne "Shared drives" -and $_.Name -ne "Other computers" } | Sort-Object Name)
      if ($sub.Count) { return $sub[0].FullName }
    }
    return $null
  }
  # Windows: a drive letter (G: by default) holding "My Drive"; mirrored: in the user's folder
  foreach ($c in @("G") + @([char[]](68..90) | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "G" })) {
    $p = "${c}:\My Drive"
    if (Test-Path $p -PathType Container) { return $p }
  }
  foreach ($n in "My Drive", "Google Drive") { $p = Join-Path $HOME $n; if (Test-Path $p -PathType Container) { return $p } }
  return $null
}
# The sync folder: the one picked by hand, else "OSRS Dashboard Sync" in Google Drive ($null = neither found)
function Get-SyncAutoFolder($st) {
  if ($st.folder) { if (Test-Path $st.folder -PathType Container) { return $st.folder } else { return $null } }
  $g = Get-SyncGoogleDrive
  if ($g) { return (Join-Path $g $SyncAutoDirName) }
  return $null
}
# The other devices' files for this player in the folder, newest per device (a cloud drive can leave copies)
function Get-SyncAutoFiles([string]$folder, [string]$ownId) {
  $byId = [ordered]@{}
  if (-not (Test-Path $folder)) { return @() }
  $norm = { param($n) (([string]$n -replace [char]160, ' ').Trim().ToLowerInvariant() -replace '[^a-z0-9_-]+', '_') }
  foreach ($f in @(Get-ChildItem $folder -File -Filter "*.osrssync" | Sort-Object Name)) {
    $first = try { $r = New-Object IO.StreamReader($f.FullName, $Utf8); try { $r.ReadLine() } finally { $r.Close() } } catch { $null }
    if (-not $first) { continue }
    $h = try { ConvertFrom-SyncJson $first.Trim([char]0xFEFF).Trim() } catch { $null }
    if (-not $h -or $h.osrsDashboardSync -ne $SyncVersion -or (& $norm $h.player) -ne (& $norm $Player)) { continue }
    $id = [string]$h.device.id
    if (-not $id -or $id -eq $ownId) { continue }
    $o = @{ path = $f.FullName; id = $id; name = [string]$h.device.name; exported = [string]$h.exported }
    if (-not $byId.Contains($id) -or (ConvertTo-SyncTime $o.exported) -gt (ConvertTo-SyncTime $byId[$id].exported)) { $byId[$id] = $o }
  }
  return @($byId.Values)
}
# Merges the other devices' newer files -> @{ imported = @(messages); error }
function Invoke-SyncAutoImport {
  $res = [ordered]@{ imported = @(); error = $null }
  if (-not $Player) { return $res }
  $st = Get-SyncState
  $folder = Get-SyncAutoFolder $st
  if (-not $folder) { return $res }
  foreach ($o in (Get-SyncAutoFiles $folder $st.id)) {
    $seen = (Get-SyncState).autoSeen
    if ($seen.Contains($o.id) -and (ConvertTo-SyncTime $seen[$o.id]) -ge (ConvertTo-SyncTime $o.exported)) { continue }
    $text = try { [IO.File]::ReadAllText($o.path, $Utf8) } catch { $null }
    if (-not $text) { continue }
    # Not whole yet (still being copied by the cloud drive): next time
    $lastLine = @($text.TrimEnd().Split([char[]]"`r`n", [StringSplitOptions]::RemoveEmptyEntries))[-1]
    if ($lastLine.Trim() -ne $SyncEndLine) { continue }
    $r = try { Import-Sync $text } catch { @(500, "{""error"":$(ConvertTo-JsonString "Import failed: $($_.Exception.Message)")}") }
    $b = try { $r[1] | ConvertFrom-Json } catch { $null }
    if ($r[0] -eq 200) {
      $st = Get-SyncState; $st.autoSeen[$o.id] = $o.exported; $st.autoError = $null; Save-SyncState $st
      $res.imported += [string]$b.message
    } else { $res.error = "$($o.name): $($b.error)" }
  }
  if ($res.error) { $st = Get-SyncState; $st.autoError = $res.error; Save-SyncState $st; Write-Host "Automatic sync: $($res.error)" }
  return $res
}
# Rewrites this device's file in the sync folder (after a Refresh)
function Invoke-SyncAutoExport {
  if (-not $Player) { return }
  $st = Get-SyncState
  $folder = Get-SyncAutoFolder $st
  if (-not $folder) { return }
  if (-not (Test-Path $folder)) { New-Item -ItemType Directory $folder -Force | Out-Null }
  $now = (Get-Date).ToUniversalTime().ToString("o")
  $text, $counts = Get-SyncExportText $st $now
  $name = "$($Player -replace '[^A-Za-z0-9 _-]', '') - $(($st.name -replace '[^A-Za-z0-9 _-]', '').Trim()) ($($st.id)).osrssync"
  $file = Join-Path $folder $name
  $part = "$file.part"
  try {
    [IO.File]::WriteAllText($part, $text, $Utf8)
    Move-Item -Force $part $file
    $st.autoExported = $now; $st.autoError = $null
    Write-Host "Automatic sync: saved $file"
  } catch {
    Remove-Item $part -Force -ErrorAction SilentlyContinue
    $st.autoError = "Could not save to ${folder}: $($_.Exception.Message)"
    Write-Host "Automatic sync: $($st.autoError)"
  }
  Save-SyncState $st
}
# POST /api/sync-folder {"folder": "<path>"} picks the folder; "" = back to Google Drive
function Set-SyncFolder([string]$body) {
  $v = try { $body | ConvertFrom-Json } catch { $null }
  $f = ([string]$v.folder).Trim()
  $st = Get-SyncState
  if (-not $f) { $st.folder = $null }
  elseif (-not (Test-Path $f -PathType Container)) { return @(400, "{""error"":$(ConvertTo-JsonString "That folder doesn't exist: $f")}") }
  else { $st.folder = $f }
  $st.autoError = $null
  Save-SyncState $st
  return @(200, '{"ok":true}')
}

# ---- Drop log with the other device's drops (plugin.ps1 Get-PluginJson) ----
# A gap line has its window ("from" < kill time <= "to"; lines from before 2026-11-08 have none and stay as they are).
# Kills the other device logged in that window were made with the plugin on, so they come off the gap (kills and
# items); a gap left with no kills is dropped.
function Get-SyncGapFixed($gapLines, $realLines) {
  $out = New-Object System.Collections.Generic.List[string]
  $raw = { param($line, $k) if ($line -match ('"' + $k + '":"([^"]*)"')) { $Matches[1] } else { $null } }
  $gaps = @(foreach ($g in $gapLines) {
    $o = try { ConvertFrom-SyncJson $g } catch { $null }
    if ($o) { @{ line = $g; o = $o; t = (& $raw $g "t"); fromS = (& $raw $g "from"); toS = (& $raw $g "to") } }
  })
  foreach ($g in $gaps) { if ($g.fromS -and $g.toS) { $g.from = ConvertTo-SyncTime $g.fromS; $g.to = ConvertTo-SyncTime $g.toS } }
  $windowed = @($gaps | Where-Object { $_.fromS -and $_.toS })
  # Only the real lines inside some window are read (in one go: ConvertFrom-Json once per line is slow)
  $inside = New-Object System.Collections.Generic.List[string]
  $insideT = New-Object System.Collections.Generic.List[datetime]
  if ($windowed.Count) {
    foreach ($l in $realLines) {
      $t = ConvertTo-SyncTime (Get-SyncLineT $l)
      foreach ($w in $windowed) { if ($t -gt $w.from -and $t -le $w.to) { $inside.Add($l); $insideT.Add($t); break } }
    }
  }
  $real = if ($inside.Count) { @(ConvertFrom-SyncJson ("[" + [string]::Join(",", [string[]]$inside) + "]")) } else { @() }
  foreach ($g in $gaps) {
    $o = $g.o
    if (-not ($g.fromS -and $g.toS) -or -not $real.Count) { $out.Add($g.line); continue }
    $kills = 0L; $drops = @{}
    for ($i = 0; $i -lt $real.Count; $i++) {
      $x = $real[$i]
      if ($x.source -ne $o.source -or $x.type -ne $o.type) { continue }
      if ($insideT[$i] -le $g.from -or $insideT[$i] -gt $g.to) { continue }
      $kills++
      foreach ($it in @($x.items)) { if ($it -and @($it).Count -ge 2) { $id = "$($it[0])"; $drops[$id] = [long]$drops[$id] + [long]$it[1] } }
    }
    if (-not $kills) { $out.Add($g.line); continue }
    $left = [long]$o.kills - $kills
    if ($left -le 0) { continue }
    $items = $null
    if ($null -ne $o.items) { $items = @(foreach ($it in @($o.items)) { if ($it -and @($it).Count -ge 2) { $q = [long]$it[1] - [long]$drops["$($it[0])"]; if ($q -gt 0) { , @([long]$it[0], $q) } } }) }
    $n = [ordered]@{ t = $g.t; source = $o.source; type = $o.type; kills = $left; gap = $true; from = $g.fromS; to = $g.toS; items = $items }
    $out.Add(($n | ConvertTo-Json -Compress -Depth 4))
  }
  return , $out
}
