# Data from the "OSRS Data Sync" RuneLite plugin (its files in .runelite\plugin-data\osrsdatasync\<player>).
# The plugin writes JSON files on this PC; nothing is downloaded. Dot-sourced by server.ps1; needs $Player, $Utf8.
#
# ~\.runelite\plugin-data\osrsdatasync\<player>\
#   progress.json    quests (0 not started, 1 in progress, 2 finished), questPoints, diaries (tier booleans),
#                    diaryTasks ("1"/"0" per task), ca (task ids), skills
#   killcounts.json  {"killCounts": {name: count}} from the game's kill count messages (bosses, raids, ...),
#                    "lootTracker": {type: {name: {kills, first, last}}} every monster/chest/clue with a drop,
#                    copied from RuneLite's Loot Tracker (first/last in ms since 1970)
#   clog.json        {"items": {id: qty}, "newByName": {name: time}} (open the log + press Search once)
#   containers.json  bank (after it was opened), inventory, equipment as [[id, qty]], GE offers
#   loot.jsonl       one line per kill/reward: {t, source, type, value, items: [[id, qty, gp each]], kc?}
#
# GET /api/plugin -> {progress, kills, clog, containers, drops: [loot.jsonl + data\plugin\loot-gaps.jsonl lines],
#                     killHistory, npcIcons} or null

$PluginRoot = Join-Path $HOME ".runelite\plugin-data\osrsdatasync"   # $HOME works on Windows and Mac

# Same folder name the plugin uses: lowercase, anything but a-z 0-9 _ - becomes "_"
function Get-PluginDir {
  $name = ($Player -replace [char]160, ' ').Trim().ToLowerInvariant() -replace '[^a-z0-9_-]+', '_'
  return Join-Path $PluginRoot $name
}
function Get-PluginFiles { @("progress.json", "killcounts.json", "clog.json", "containers.json", "loot.jsonl" | ForEach-Object { Join-Path (Get-PluginDir) $_ }) + $KillHistoryFile + $LootGapFile + $NpcIconDir + $LootOtherFile + $GapsOtherFile }

function Get-PluginJson {
  $dir = Get-PluginDir
  if (-not (Test-Path $dir)) { return "null" }
  # A plugin file as it is. An empty or cut-off file (crash, full disk) is sent as null, so one bad file can't make
  # the whole answer invalid JSON (the page would lose every plugin section)
  $read = {
    param($n)
    $f = Join-Path $dir $n
    if (-not (Test-Path $f)) { return "null" }
    $text = [IO.File]::ReadAllText($f, $Utf8).Trim()
    if ($text.StartsWith("{") -and $text.EndsWith("}")) { return $text }
    Write-Host "Plugin file $n is empty or cut off; skipped"
    return "null"
  }

  # The loot log lines themselves (newest $DropLogMax) go to the page for the Drop log. Only whole
  # lines: one still being written is left for the next request.
  $whole = {
    param($file)
    $out = New-Object System.Collections.Generic.List[string]
    if (Test-Path $file) {
      foreach ($line in [IO.File]::ReadAllLines($file, $Utf8)) {
        $l = $line.Trim()
        if ($l.StartsWith('{"t":"') -and $l.EndsWith("}")) { $out.Add($l) }
      }
    }
    return , $out
  }
  $ownLoot = & $whole (Join-Path $dir "loot.jsonl")
  $DropLogMax = 5000   # ~120 bytes each: the page never gets more than ~0.6 MB of drop log
  # Kills done without the plugin (Update-PluginLootGaps): "gap": true lines, same shape plus "kills"
  $ownGaps = & $whole $LootGapFile
  $drops = New-Object System.Collections.Generic.List[string]
  if ((Test-Path $LootOtherFile) -or (Test-Path $GapsOtherFile)) {
    # Imported from another device (sync.ps1): its drops, and each device's gaps less the drops the other one
    # logged in that gap's window; all by time, so the newest $DropLogMax are the newest of both devices
    $otherLoot = & $whole $LootOtherFile
    $all = New-Object System.Collections.Generic.List[string]
    $all.AddRange($ownLoot); $all.AddRange($otherLoot)
    $all.AddRange((Get-SyncGapFixed $ownGaps $otherLoot)); $all.AddRange((Get-SyncGapFixed (& $whole $GapsOtherFile) $ownLoot))
    $drops = Sort-SyncLines $all $SyncByT
  } else { $drops.AddRange($ownLoot); $drops.AddRange($ownGaps) }
  $dropsJson = if ($drops.Count -gt $DropLogMax) { $drops.GetRange($drops.Count - $DropLogMax, $DropLogMax) -join "," } else { $drops -join "," }

  $hist = if (Test-Path $KillHistoryFile) { ([IO.File]::ReadAllLines($KillHistoryFile, $Utf8) | Where-Object { $_.Trim() }) -join "," } else { "" }
  return "{""progress"":$(& $read 'progress.json'),""kills"":$(& $read 'killcounts.json'),""clog"":$(& $read 'clog.json')," +
         """containers"":$(& $read 'containers.json'),""drops"":[$dropsJson],""killHistory"":[$hist],""npcIcons"":$(ConvertTo-Json @(Get-NpcIconSlugs) -Compress)}"
}

# ---- Quests, diaries, combat achievements (progress.json) -> data\progress\latest.json + history.jsonl ----
# "src":"plugin".
# Diaries: [done, n, flags], flags = "1"/"0" per task in diary-tasks.json order (n = its task count). A finished tier
# is [n, n, "11..1"]. Without the plugin's task flags (older plugin) an unfinished tier is [null, n, ""] (unknown).
function Update-PluginProgress {
  $file = Join-Path (Get-PluginDir) "progress.json"
  if (-not (Test-Path $file)) { return "Progress: no progress.json yet (log in with OSRS Data Sync on)" }
  $p = [IO.File]::ReadAllText($file, $Utf8) | ConvertFrom-Json
  if (-not $p.quests) { return "Progress: progress.json has no quests yet" }
  if (Test-SyncStale "progress" ([IO.File]::ReadAllText($file, $Utf8) -replace '(?s)^.*?"updated":"([^"]*)".*$', '$1')) { return "Progress: skipped (older than the data imported from your other device; log in to RuneLite here to update it)" }
  $dirW = Join-Path $DataDir "progress"
  if (-not (Test-Path $dirW)) { New-Item -ItemType Directory $dirW | Out-Null }
  $taskFile = Join-Path $dirW "diary-tasks.json"
  $info = if (Test-Path $taskFile) { [IO.File]::ReadAllText($taskFile, $Utf8) | ConvertFrom-Json } else { $null }

  $quests = [ordered]@{}
  foreach ($q in $p.quests.PSObject.Properties) { $quests[$q.Name] = [int]$q.Value }
  $diaries = [ordered]@{}
  foreach ($region in $p.diaries.PSObject.Properties) {
    $tiers = [ordered]@{}
    foreach ($tier in "Easy", "Medium", "Hard", "Elite") {
      $n = if ($info) { @($info.($region.Name).$tier.tasks | Where-Object { $_ }).Count } else { 0 }
      $flags = [string]$p.diaryTasks.($region.Name).$tier
      if ($region.Value.$tier) { $tiers[$tier] = @($n, $n, ("1" * $n)) }
      elseif ($n -and $flags.Length -eq $n -and $flags -match '^[01]+$') { $tiers[$tier] = @(($flags.ToCharArray() | Where-Object { $_ -eq [char]"1" }).Count, $n, $flags) }
      else { $tiers[$tier] = @($null, $n, "") }
    }
    $diaries[$region.Name] = $tiers
  }
  $ca = @($p.ca | ForEach-Object { [int]$_ } | Sort-Object)
  $slim = [ordered]@{ v = 3; src = "plugin"; timestamp = [string]$p.updated; quests = $quests; diaries = $diaries; ca = $ca } | ConvertTo-Json -Compress -Depth 6

  $latestFile = Join-Path $dirW "latest.json"
  $prevRaw = if (Test-Path $latestFile) { [IO.File]::ReadAllText($latestFile, $Utf8) } else { "" }
  $noStamp = '"timestamp":"[^"]*",'
  if (($prevRaw -replace $noStamp, "") -eq ($slim -replace $noStamp, "")) {
    if ($prevRaw -ne $slim) { [IO.File]::WriteAllText($latestFile, $slim, $Utf8) }
    return "Progress: no change"
  }
  [IO.File]::WriteAllText($latestFile, $slim, $Utf8)
  [IO.File]::AppendAllText((Join-Path $dirW "history.jsonl"), $slim + "`n", $Utf8)
  return "Progress: saved ($(@($quests.Values | Where-Object { $_ -eq 2 }).Count)/$($quests.Count) quests, $($ca.Count) combat tasks)"
}

# ---- Collection log (clog.json) -> data\clog\history.jsonl, same line format as before ----
# {"t","changed","total","available","items":{"<id>":[count,"<date first seen>"]}}. Items are merged with the
# previous line (higher count wins), so a partial plugin file (log not searched yet) never removes items.
# A new item's date = this Refresh (the plugin's log has no dates). Names/categories: the saved
# data\clog\items.json + categories.json (OSRS Wiki, tools\fetch-clog-layout.ps1); names of unknown ids come from the wiki.
function Update-PluginClog {
  $file = Join-Path (Get-PluginDir) "clog.json"
  if (-not (Test-Path $file)) { return "Collection log: no clog.json yet (open the log in game and press Search once)" }
  $c = [IO.File]::ReadAllText($file, $Utf8) | ConvertFrom-Json
  if (-not (Test-Path $ClogDir)) { New-Item -ItemType Directory $ClogDir | Out-Null }
  $histFile = Join-Path $ClogDir "history.jsonl"
  $prev = $null
  if (Test-Path $histFile) {
    $last = [IO.File]::ReadAllLines($histFile, $Utf8) | Where-Object { $_.Trim() } | Select-Object -Last 1
    if ($last) { $prev = $last | ConvertFrom-Json }
  }
  $prevItems = if ($prev) { ConvertTo-Hash $prev.items } else { @{} }
  $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
  $items = [ordered]@{}
  foreach ($id in $prevItems.Keys) { $items[$id] = @([int]$prevItems[$id][0], [string]$prevItems[$id][1]) }
  $logIds = Get-AllLogIds
  $logSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@($logIds))
  # Drops of collection log items (loot.jsonl), duplicates included, count straight into the log: the game
  # only posts a chat message for NEW items, so before this a duplicate waited for the log to be opened in game.
  # Marker = the last drop already counted (lootT on the line); the first time, the plugin's clog.json write time.
  $lootT = if ($prev -and $prev.lootT) { [string]$prev.lootT } else { [string]$c.updated }
  $dropAdd = @{}; $dropDate = @{}
  $lootFile = Join-Path (Get-PluginDir) "loot.jsonl"
  if ($lootT -and (Test-Path $lootFile)) {
    $marker = [DateTime]::Parse($lootT).ToUniversalTime()
    $lines = [IO.File]::ReadAllLines($lootFile, $Utf8)
    $newest = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {   # newest first, stop at the marker
      if ($lines[$i] -notmatch '"t":"([^"]+)"') { continue }
      $tText = $Matches[1]
      $t = [DateTime]::Parse($tText).ToUniversalTime()
      if ($t -le $marker) { break }
      # A line still being written (or a damaged one) is skipped. Throwing here failed the whole collection log on
      # every Refresh, because the marker never got past that line
      $entry = try { $lines[$i] | ConvertFrom-Json } catch { $null }
      if (-not $entry) { continue }
      if (-not $newest) { $newest = $tText }
      foreach ($d in @($entry.items)) {
        $id = [string]$d[0]
        if (-not $logSet.Contains($id)) { continue }
        $dropAdd[$id] = [int]$dropAdd[$id] + [int]$d[1]
        $dropDate[$id] = $t.ToString("yyyy-MM-dd HH:mm:ss")   # ends on the earliest drop
      }
    }
    if ($newest) { $lootT = $newest }
  }
  # Log items among the drops of kills done without the plugin (loot-gaps.jsonl, Update-PluginLootGaps runs first).
  # Marker = how many gap lines are already counted (gapN on the line). Same max() rule below, so an item the
  # plugin's own Search already counted isn't added twice.
  $gapN = if ($prev -and $null -ne $prev.gapN) { [int]$prev.gapN } else { 0 }
  if (Test-Path $LootGapFile) {
    $gl = @([IO.File]::ReadAllLines($LootGapFile, $Utf8) | Where-Object { $_.Trim() })
    for ($i = $gapN; $i -lt $gl.Count; $i++) {
      $entry = try { $gl[$i] | ConvertFrom-Json } catch { $null }
      if (-not $entry -or -not $entry.items) { continue }
      $t = [DateTime]::Parse($entry.t).ToUniversalTime()
      foreach ($d in @($entry.items)) {
        $id = [string]$d[0]
        if (-not $logSet.Contains($id)) { continue }
        $dropAdd[$id] = [int]$dropAdd[$id] + [int]$d[1]
        if (-not $dropDate[$id]) { $dropDate[$id] = $t.ToString("yyyy-MM-dd HH:mm:ss") }
      }
    }
    $gapN = $gl.Count
  }
  # Count = the higher of the plugin's own count and the last saved count plus those drops, so a drop the
  # plugin already counted itself is never added twice.
  $plugin = @{}
  foreach ($it in $c.items.PSObject.Properties) { if ([int]$it.Value -gt 0) { $plugin[$it.Name] = [int]$it.Value } }
  # New items from the game's "New item added to your collection log" message (newByName): the plugin only fills
  # "items" when the log is opened, so a new item that wasn't a loot.jsonl drop (e.g. from a skilling action) was
  # missing and its hiscores slot got a guessed source. Name -> log id via the saved names; a name shared by
  # several log ids is skipped. Counts as at least 1, dated at the message.
  $newDate = @{}
  if ($c.newByName) {
    $namesRaw = Read-ClogFile "items.json"
    $nameMap = if ($namesRaw) { ConvertTo-Hash ($namesRaw | ConvertFrom-Json).items } else { @{} }
    $byName = @{}
    foreach ($id in $logSet) {
      $n = $nameMap[$id]; if (-not $n) { continue }
      $k = ([string]@($n)[0]).ToLowerInvariant()
      $byName[$k] = if ($byName.ContainsKey($k) -and $byName[$k] -ne $id) { "" } else { $id }
    }
    foreach ($p in $c.newByName.PSObject.Properties) {
      $id = $byName[$p.Name.ToLowerInvariant()]
      if (-not $id) { continue }
      if ([int]$plugin[$id] -lt 1) { $plugin[$id] = 1 }
      $newDate[$id] = try { [DateTime]::Parse([string]$p.Value).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss") } catch { $now }
    }
  }
  $changes = 0
  $ids = New-Object 'System.Collections.Generic.HashSet[string]'   # Select-Object -Unique is O(n^2) in PS 5.1
  foreach ($id in @($plugin.Keys) + @($dropAdd.Keys)) { [void]$ids.Add($id) }
  foreach ($id in $ids) {
    $had = if ($items.Contains($id)) { [int]$items[$id][0] } else { 0 }
    # The first time (nothing saved yet) the drops are counted on top of the plugin's count: they all came after its
    # clog.json was written (the marker), so it can't hold them yet. Later the saved count is the base.
    $base = if ($prev) { $had } else { [int]$plugin[$id] }
    $q = [Math]::Max([int]$plugin[$id], $base + [int]$dropAdd[$id])
    if ($q -le $had) { continue }
    if ($items.Contains($id)) { $items[$id] = @($q, $items[$id][1]) }
    else { $items[$id] = @($q, $(if ($newDate[$id]) { $newDate[$id] } elseif ($dropDate[$id]) { $dropDate[$id] } else { $now })) }
    $changes++
  }
  $available = [Math]::Max([int]$logIds.Count, [int]$prev.available)
  $status = "no change"
  if ($changes -or -not $prev) {
    $line = [ordered]@{ t = (Get-Date).ToUniversalTime().ToString("o"); changed = $now; src = "plugin"
      total = $items.Count; available = $available; lootT = $lootT; gapN = $gapN; items = $items } | ConvertTo-Json -Compress -Depth 5
    [IO.File]::AppendAllText($histFile, $line + "`n", $Utf8)
    $status = "saved ($changes item$(if ($changes -ne 1) { 's' }) new or increased)"
  }
  # Names for ids the saved list doesn't know (new content): the wiki, via the bank's name lookup
  $namesRaw = Read-ClogFile "items.json"
  $names = if ($namesRaw) { ConvertTo-Hash ($namesRaw | ConvertFrom-Json).items } else { @{} }
  $unknown = @($items.Keys | Where-Object { -not $names.ContainsKey($_) })
  if ($unknown.Count) {
    try {
      [void](Update-BankItems $unknown)
      $bankNames = Read-BankHash "items.json"
      foreach ($id in $unknown) { if ($bankNames[$id]) { $names[$id] = @($bankNames[$id])[0] } }
      Save-ClogFile "items.json" ([ordered]@{ items = $names } | ConvertTo-Json -Compress)
    } catch { Write-Host "Collection log names failed: $($_.Exception.Message)" }
  }
  Update-ClogImages (@($items.Keys) + $logIds)
  # Prices only for the log items you've obtained
  $obtained = @($items.Keys | Where-Object { [long]$items[$_][0] -gt 0 })
  $prices = try { Update-ClogPrices ($changes -gt 0) $obtained } catch { "prices unavailable: $($_.Exception.Message)" }
  return "Collection log (OSRS Data Sync): $status ($($items.Count)/$available) - $prices"
}

# Bank + equipment + inventory from containers.json for bank.ps1's Update-Bank, or $null when there is no
# file or the bank was never opened with the plugin on. Lists as @{id; qty} objects.
function Get-PluginContainers {
  $file = Join-Path (Get-PluginDir) "containers.json"
  if (-not (Test-Path $file)) { return $null }
  $c = [IO.File]::ReadAllText($file, $Utf8) | ConvertFrom-Json
  # No "bank" at all = never opened with the plugin on. "bank": [] = it was opened and really is empty (a new account)
  if (-not $c.PSObject.Properties['bank'] -or $null -eq $c.bank) { return $null }
  $conv = { param($list) , @(foreach ($p in @($list)) { if ($p) { [pscustomobject]@{ id = [int]$p[0]; qty = [long]$p[1] } } }) }
  return [pscustomobject]@{
    bank = (& $conv $c.bank); equipment = (& $conv $c.equipment); inventory = (& $conv $c.inventory)
    # Rune pouch contents as the game has them; $null from plugin versions that didn't send it yet
    runePouch = if ($c.PSObject.Properties['runePouch']) { & $conv $c.runePouch } else { $null }
    # Inventory as laid out in game: [slot, id, qty] (plugin versions from 2026-11-01 send the slot third)
    invLayout = @(foreach ($p in @($c.inventory)) { if ($p -and @($p).Count -ge 3) { , @([int]$p[2], [int]$p[0], [long]$p[1]) } })
    # Grand Exchange offers as the JSON text of a bank history line; $null from plugin versions that didn't send them
    ge = if ($c.PSObject.Properties['ge']) { "[" + (@(foreach ($o in @($c.ge)) { if ($o) { "{""item"":[$([long]$o.id),$([long]$o.total)],""done"":$([long]$o.done),""price"":$([long]$o.price),""spent"":$([long]$o.spent),""state"":""$($o.state)""}" } }) -join ",") + "]" } else { $null }
    bankAt = [long]$c.bankAt
    updated = [DateTime]::Parse([string]$c.updated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
  }
}

# Kill history for the Recent activity feed: on each Refresh, one line with every Loot Tracker total, only when
# something changed. data\plugin\kills-history.jsonl: {"t": refresh time, "k": {"TYPE|name": kills}}
$PluginDataDir = Join-Path $DataDir "plugin"
$KillHistoryFile = Join-Path $PluginDataDir "kills-history.jsonl"

# ---- Monster pictures for the Kills & loot list ----
# icons\npc\<slug>.png: the monster's picture from the OSRS Wiki (infobox_monster, else infobox_npc; the version named
# exactly "<Name>.png" if there is one), shrunk to fit 64 px and outlined in white like every icon. Looked up and
# downloaded on Refresh only (Update-PluginKills), never when the page asks. data\plugin\npc-images.json remembers
# name -> wiki file ("" = no picture), so each name is looked up once.
$NpcIconDir = Join-Path $Root "icons\npc"
function Get-NpcSlug([string]$name) { ($name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }
function Get-NpcIconSlugs { if (Test-Path $NpcIconDir) { @(Get-ChildItem $NpcIconDir -Filter *.png | ForEach-Object { $_.BaseName }) } else { @() } }

function Update-NpcIcons([string[]]$names) {
  $mapFile = Join-Path $PluginDataDir "npc-images.json"
  $map = @{}
  if (Test-Path $mapFile) { $map = ConvertTo-Hash ([IO.File]::ReadAllText($mapFile, $Utf8) | ConvertFrom-Json) }
  $todo = @($names | Where-Object { $_ -and -not $map.ContainsKey($_) } | Sort-Object -Unique)
  # Normally nothing is left to look up: tools\fetch-all-icons.ps1 fills npc-images.json with every monster/NPC
  foreach ($bucketName in "infobox_monster", "infobox_npc") {
    $field = if ($bucketName -eq "infobox_npc") { "page_name" } else { "name" }   # infobox_npc has no 'name'
    $left = @($todo | Where-Object { -not $map[$_] })
    for ($i = 0; $i -lt $left.Count; $i += 30) {
      $batch = @($left[$i..([Math]::Min($i + 29, $left.Count - 1))])
      $or = ($batch | ForEach-Object { "{'$field','$($_ -replace "'", "\'")'}" }) -join ","
      $q = "bucket('$bucketName').select('$field','image').where(bucket.Or($or)).limit(1000).run()"
      $res = try { Get-Web "${WikiApi}?action=bucket&format=json&query=$([uri]::EscapeDataString($q))" | ConvertFrom-Json } catch { $null }
      $found = @{}
      foreach ($row in @($res.bucket)) {
        $n = [string]$row.$field
        foreach ($img in @($row.image)) {
          $file = ([string]$img) -replace '^File:', ''
          if (-not $file) { continue }
          if ($file -eq "$n.png") { $found[$n] = $file } elseif (-not $found[$n]) { $found[$n] = $file }
        }
      }
      foreach ($n in $batch) { if ($found[$n]) { $map[$n] = $found[$n] } }
      Start-Sleep -Milliseconds 300
    }
  }
  foreach ($n in $todo) { if (-not $map.ContainsKey($n)) { $map[$n] = "" } }
  if ($todo.Count) {
    if (-not (Test-Path $PluginDataDir)) { New-Item -ItemType Directory $PluginDataDir | Out-Null }
    [IO.File]::WriteAllText($mapFile, ($map | ConvertTo-Json -Compress), $Utf8)
  }

  # Download the pictures not saved yet (at most 80 per Refresh)
  if (-not (Test-Path $NpcIconDir)) { New-Item -ItemType Directory $NpcIconDir | Out-Null }
  Add-Type -AssemblyName System.Drawing
  $saved = 0; $tried = 0
  foreach ($n in $names) {
    if (-not $map[$n]) { continue }
    $out = Join-Path $NpcIconDir "$(Get-NpcSlug $n).png"
    if (Test-Path $out) { continue }
    if ($script:NoIcon -and $script:NoIcon.Contains("npc/$(Get-NpcSlug $n)")) { continue }   # wiki has none
    if (++$tried -gt 80) { break }
    try {
      # 64 px thumbnail (it is shrunk to 64 px anyway); Special:Redirect follows renamed files
      $url = "https://oldschool.runescape.wiki/w/Special:Redirect/file/" + [uri]::EscapeDataString(($map[$n] -replace ' ', '_')) + "?width=64"
      $ProgressPreference = "SilentlyContinue"
      $bytes = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -UserAgent $ClogUA).Content
      $src = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $bytes)))
      $scale = [Math]::Min(1.0, 64.0 / [Math]::Max($src.Width, $src.Height))
      $w = [Math]::Max(1, [int]($src.Width * $scale)); $h = [Math]::Max(1, [int]($src.Height * $scale))
      $bmp = New-Object Drawing.Bitmap $w, $h
      $g = [Drawing.Graphics]::FromImage($bmp)
      $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.DrawImage($src, 0, 0, $w, $h); $g.Dispose(); $src.Dispose()
      $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
      [IO.File]::WriteAllBytes($out, (Add-IconOutline $ms.ToArray()))
      $saved++
    } catch {
      Write-Host "Monster picture failed for ${n}: $($_.Exception.Message)"
      if (Get-Command Add-NoIcon -ErrorAction SilentlyContinue) { Add-NoIcon "npc/$(Get-NpcSlug $n)" $_ }
    }
  }
  return "monster pictures: $saved saved, $(@($map.Values | Where-Object { $_ }).Count) known"
}

function Update-PluginKills([string]$time) {
  $file = Join-Path (Get-PluginDir) "killcounts.json"
  if (-not (Test-Path $file)) { return "Plugin kills: no killcounts.json yet (log in with the plugin on)" }
  $kc = [IO.File]::ReadAllText($file, $Utf8) | ConvertFrom-Json
  $k = [ordered]@{}
  $ids = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($type in @($kc.lootTracker.PSObject.Properties)) {
    foreach ($src in @($type.Value.PSObject.Properties)) {
      $k["$($type.Name)|$($src.Name)"] = [long]$src.Value.kills
      if ($src.Value.drops) { foreach ($d in $src.Value.drops.PSObject.Properties) { [void]$ids.Add($d.Name) } }
    }
  }
  # Names (and wiki pictures) for dropped items, looked up once per new id, like the bank's
  $names = if ($ids.Count) { try { Update-BankItems @($ids) } catch { "names failed: $($_.Exception.Message)" } } else { "no drops listed" }
  # Their pictures, downloaded from the wiki once and kept in icons\item\ (the page then never waits on the wiki).
  # At most 300 per Refresh so the first one stays quick; the rest come on later Refreshes or when shown.
  $iconDir = Join-Path $Root "icons\item"
  $missing = @($ids | Where-Object { -not (Test-Path (Join-Path $iconDir "$_.png")) } | Select-Object -First 300)
  $gotIcons = 0
  foreach ($id in $missing) { try { if (Get-ItemIcon $id) { $gotIcons++ } } catch { } }
  if ($missing.Count) { $names += "; drop icons saved: $gotIcons of $($missing.Count)" }
  # Pictures of the monsters and pickpocket targets (chests / clues keep their item picture)
  $npcNames = @(foreach ($tn in "NPC", "PICKPOCKET") { if ($kc.lootTracker.$tn) { $kc.lootTracker.$tn.PSObject.Properties.Name } })
  if ($npcNames.Count) { $names += "; " + $(try { Update-NpcIcons $npcNames } catch { "monster pictures failed: $($_.Exception.Message)" }) }

  if (-not $k.Count) { return "Plugin kills: Loot Tracker has nothing yet; $names" }
  if (Test-SyncStale "killcounts" ([IO.File]::ReadAllText($file, $Utf8) -replace '(?s)^.*?"updated":"([^"]*)".*$', '$1')) { return "Plugin kills: skipped (older than the data imported from your other device); $names" }
  $json = $k | ConvertTo-Json -Compress
  if (-not (Test-Path $PluginDataDir)) { New-Item -ItemType Directory $PluginDataDir | Out-Null }
  if (Test-Path $KillHistoryFile) {
    $last = [IO.File]::ReadAllLines($KillHistoryFile, $Utf8) | Where-Object { $_.Trim() } | Select-Object -Last 1
    if ($last -and (($last -replace '^\{"t":"[^"]*","k":', '') -replace '\}$', '') -eq $json) { return "Plugin kills: no new kills; $names" }
  }
  [IO.File]::AppendAllText($KillHistoryFile, "{""t"":""$time"",""k"":$json}`n", $Utf8)
  return "Plugin kills: saved ($($k.Count) sources); $names"
}

# ---- Drop log gaps ----
# loot.jsonl only gets a line while the plugin runs. Kills done without it (the plugin turned off, missing from a
# client, or an old plugin bug like the NpcLootReceived one) still reach RuneLite's Loot
# Tracker totals, which the plugin copies into killcounts.json at its next login. So on every Refresh: Loot Tracker
# totals now - totals last time - loot.jsonl lines in between = kills + drops the drop log is missing. Those go to
# data\plugin\loot-gaps.jsonl, same shape as loot.jsonl plus "kills": n and "gap": true, dated at the source's
# last kill (Loot Tracker "last"). Works for every type: monsters, bosses, raids, chests, clues, pickpocketing.
# data\plugin\loot-base.json {"t": killcounts.json "updated", "k": {"TYPE|name": {"kills": n, "drops": {id: q}}}}
#   = what is accounted for up to t. Never hand-edit either file.
# First run (no loot-base.json): kills-history.jsonl windows since the drop log began give the kills missed before;
# their drops weren't saved anywhere then, so those lines have "items": null.
$LootBaseFile = Join-Path $PluginDataDir "loot-base.json"
$LootGapFile  = Join-Path $PluginDataDir "loot-gaps.jsonl"
function ConvertTo-Utc([string]$iso) { [DateTimeOffset]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
function Update-PluginLootGaps {
  $dir = Get-PluginDir
  $kcFile = Join-Path $dir "killcounts.json"
  if (-not (Test-Path $kcFile)) { return "Drop log gaps: no killcounts.json yet" }
  $kcText = [IO.File]::ReadAllText($kcFile, $Utf8).Trim()
  if (-not ($kcText.StartsWith("{") -and $kcText.EndsWith("}"))) { return "Drop log gaps: killcounts.json cut off; skipped" }
  $kc = $kcText | ConvertFrom-Json
  if (-not $kc.updated -or -not $kc.lootTracker) { return "Drop log gaps: Loot Tracker has nothing yet" }
  $U = ConvertTo-Utc $kc.updated

  # Current totals per source
  $cur = @{}
  foreach ($type in @($kc.lootTracker.PSObject.Properties)) {
    foreach ($src in @($type.Value.PSObject.Properties)) {
      $d = @{}
      if ($src.Value.drops) { foreach ($p in $src.Value.drops.PSObject.Properties) { $d[$p.Name] = [long]$p.Value } }
      $cur["$($type.Name)|$($src.Name)"] = @{ type = $type.Name; name = $src.Name; kills = [long]$src.Value.kills; drops = $d; last = [long]$src.Value.last }
    }
  }
  # The live drop log: whole lines only, parsed; a bad line is skipped
  $live = New-Object System.Collections.Generic.List[object]
  $lootFile = Join-Path $dir "loot.jsonl"
  if (Test-Path $lootFile) {
    foreach ($line in [IO.File]::ReadAllLines($lootFile, $Utf8)) {
      $l = $line.Trim()
      if (-not ($l.StartsWith('{"t":"') -and $l.EndsWith("}"))) { continue }
      try { $o = $l | ConvertFrom-Json; $live.Add(@{ t = (ConvertTo-Utc $o.t); key = "$($o.type)|$($o.source)"; items = $o.items }) } catch { }
    }
  }
  # Kills and drops the live log has per source in (from, to]
  $liveIn = {
    param($from, $to)
    $m = @{}
    foreach ($x in $live) {
      if ($x.t -le $from -or $x.t -gt $to) { continue }
      if (-not $m.ContainsKey($x.key)) { $m[$x.key] = @{ kills = 0L; drops = @{} } }
      $e = $m[$x.key]; $e.kills++
      foreach ($it in @($x.items)) { if ($it -and @($it).Count -ge 2) { $id = "$($it[0])"; $e.drops[$id] = [long]$e.drops[$id] + [long]$it[1] } }
    }
    return $m
  }
  $lines = New-Object System.Collections.Generic.List[string]
  $gapLine = {
    param($c, [datetime]$from, [datetime]$to, [long]$kills, $items)
    # Dated at the source's last kill when that falls in the window, else at the window's end
    $at = if ($c.last -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($c.last).UtcDateTime } else { $to }
    if ($at -le $from -or $at -gt $to) { $at = $to }
    # from / to: the window, so kills logged on another device in it can come off this gap (sync.ps1 Get-SyncGapFixed)
    $o = [ordered]@{ t = $at.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"); source = $c.name; type = $c.type; kills = $kills; gap = $true
      from = $from.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"); to = $to.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"); items = $items }
    $lines.Add(($o | ConvertTo-Json -Compress -Depth 4))
  }

  if (-not (Test-Path $LootBaseFile)) {
    # First run: kills-history windows since the drop log began (kills only; drops weren't saved then)
    $acc = @{}
    $kh = @()
    if ($live.Count -and (Test-Path $KillHistoryFile)) {
      $kh = @(foreach ($l in [IO.File]::ReadAllLines($KillHistoryFile, $Utf8)) { if ($l.Trim()) { try { $o = $l | ConvertFrom-Json; @{ t = (ConvertTo-Utc $o.t); k = $o.k } } catch { } } })
    }
    if ($kh.Count) {
      $logStart = [datetime]::MaxValue; foreach ($x in $live) { if ($x.t -lt $logStart) { $logStart = $x.t } }
      $s = 0; for ($i = 0; $i -lt $kh.Count; $i++) { if ($kh[$i].t -le $logStart) { $s = $i } }
      # Windows: kills-history line s -> s+1 -> ... -> the current totals
      $points = @($kh[$s..($kh.Count - 1)] | ForEach-Object { $k = @{}; foreach ($p in $_.k.PSObject.Properties) { $k[$p.Name] = [long]$p.Value }; @{ t = $_.t; k = $k } })
      $now = @{}; foreach ($key in $cur.Keys) { $now[$key] = $cur[$key].kills }
      if ($U -gt $points[-1].t) { $points += @{ t = $U; k = $now } }
      foreach ($key in $points[0].k.Keys) { $acc[$key] = $points[0].k[$key] }
      for ($i = 1; $i -lt $points.Count; $i++) {
        $from = $points[$i - 1].t; $to = $points[$i].t
        $lv = & $liveIn $from $to
        foreach ($key in $points[$i].k.Keys) {
          $n = $points[$i].k[$key]; $a = if ($acc.ContainsKey($key)) { $acc[$key] } else { 0L }
          if ($n -lt $a) { $acc[$key] = $n; continue }   # Loot Tracker reset
          $lk = if ($lv.ContainsKey($key)) { $lv[$key].kills } else { 0L }
          $miss = $n - $a - $lk
          if ($miss -gt 0) {
            $c = if ($cur.ContainsKey($key)) { $cur[$key] } else { $t, $nm = $key -split '\|', 2; @{ type = $t; name = $nm; last = 0L } }
            & $gapLine $c $from $to $miss $null
            $acc[$key] = $n
          } else { $acc[$key] = [Math]::Max($n, $a + $lk) }   # live line not in the totals yet: count it once
        }
      }
    }
    $base = @{}
    foreach ($key in $cur.Keys) {
      $k = $cur[$key].kills; if ($acc.ContainsKey($key)) { $k = [Math]::Max($k, $acc[$key]) }
      $base[$key] = @{ kills = $k; drops = $cur[$key].drops }
    }
    # Lines written after the totals were saved are counted from the next Refresh on
  } else {
    $b = [IO.File]::ReadAllText($LootBaseFile, $Utf8) | ConvertFrom-Json
    $T = ConvertTo-Utc $b.t
    if ($U -le $T) { return "Drop log gaps: none (no new Loot Tracker totals)" }
    $old = @{}
    foreach ($p in $b.k.PSObject.Properties) {
      $d = @{}; if ($p.Value.drops) { foreach ($q in $p.Value.drops.PSObject.Properties) { $d[$q.Name] = [long]$q.Value } }
      $old[$p.Name] = @{ kills = [long]$p.Value.kills; drops = $d }
    }
    $lv = & $liveIn $T $U
    $base = @{}
    foreach ($key in $cur.Keys) {
      $c = $cur[$key]
      $o = if ($old.ContainsKey($key)) { $old[$key] } else { @{ kills = 0L; drops = @{} } }
      $l = if ($lv.ContainsKey($key)) { $lv[$key] } else { @{ kills = 0L; drops = @{} } }
      if ($c.kills -lt $o.kills) { $base[$key] = @{ kills = $c.kills; drops = $c.drops }; continue }   # Loot Tracker reset
      $miss = $c.kills - $o.kills - $l.kills
      $ids = New-Object 'System.Collections.Generic.HashSet[string]'
      foreach ($id in @($c.drops.Keys) + @($o.drops.Keys) + @($l.drops.Keys)) { [void]$ids.Add($id) }
      if ($miss -gt 0) {
        $items = @(foreach ($id in $ids) { $q = [long]$c.drops[$id] - [long]$o.drops[$id] - [long]$l.drops[$id]; if ($q -gt 0) { , @([long]$id, $q) } })
        & $gapLine $c $T $U $miss $items
        $base[$key] = @{ kills = $c.kills; drops = $c.drops }
      } else {
        # Nothing missing. A live line the totals don't have yet (saved a moment later) is counted once only.
        $d = @{}; foreach ($id in $ids) { $d[$id] = [Math]::Max([long]$c.drops[$id], [long]$o.drops[$id] + [long]$l.drops[$id]) }
        $base[$key] = @{ kills = [Math]::Max($c.kills, $o.kills + $l.kills); drops = $d }
      }
    }
  }
  if (-not (Test-Path $PluginDataDir)) { New-Item -ItemType Directory $PluginDataDir | Out-Null }
  if ($lines.Count) { [IO.File]::AppendAllText($LootGapFile, (($lines -join "`n") + "`n"), $Utf8) }
  $tmp = "$LootBaseFile.tmp"
  [IO.File]::WriteAllText($tmp, ([ordered]@{ t = $kc.updated; k = $base } | ConvertTo-Json -Compress -Depth 5), $Utf8)
  Move-Item -Force $tmp $LootBaseFile
  $killsAdded = 0; foreach ($l in $lines) { $killsAdded += [long](($l | ConvertFrom-Json).kills) }
  return "Drop log gaps: " + $(if ($lines.Count) { "$killsAdded kills from $($lines.Count) entries added (played without the plugin)" } else { "none" })
}
