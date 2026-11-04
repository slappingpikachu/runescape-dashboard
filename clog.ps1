# Collection log for the page. The items come only from the OSRS Data Sync RuneLite plugin
# (plugin.ps1 Update-PluginClog, on Refresh); no other plugin or site is used. Names, pictures and GE prices come
# from the OSRS Wiki.
# Dot-sourced by server.ps1; needs $DataDir, $Root, $Player, $Utf8 and Add-IconOutline.
#
# data\clog\history.jsonl   one line per change (new item or a higher count):
#                           {"t":ISO,"changed":"yyyy-MM-dd HH:mm:ss","total":n,"available":n,"src":"plugin",
#                            "items":{"<id>":[count,"<date first seen>"],...}}  (lines without src: saved Oct 24 - Nov 1, before the plugin)
# data\clog\items.json      id -> item name (OSRS Wiki, tools\fetch-clog-layout.ps1; new ids get their name from the wiki)
# data\clog\categories.json {"names":{page:"Page name"}, tab:{page:[ids]}} in collection log order (OSRS Wiki,
#                           tools\fetch-clog-layout.ps1; run it again when Jagex adds log items)
# data\clog\images.json     id -> OSRS Wiki image file, for icons\item\<id>.png

$ClogDir    = Join-Path $DataDir "clog"
$WikiApi    = "https://oldschool.runescape.wiki/api.php"
$ClogUA     = "osrs-progress-dashboard/1.0 (self-hosted OSRS progress dashboard)"

function Read-ClogFile([string]$name) {
  $f = Join-Path $ClogDir $name
  if (Test-Path $f) { return [IO.File]::ReadAllText($f, $Utf8) }
  return $null
}
function Save-ClogFile([string]$name, [string]$text) {
  [IO.File]::WriteAllText((Join-Path $ClogDir $name), $text, $Utf8)
}
function Get-Web([string]$url) {
  # Refresh downloads the GE prices in parallel with the hiscores up front (server.ps1 Invoke-Refresh)
  if ($script:Prefetch -and $script:Prefetch.ContainsKey($url)) { return $script:Prefetch[$url] }
  $ProgressPreference = "SilentlyContinue"   # PS 5.1's progress bar makes downloads much slower
  $body = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -UserAgent $ClogUA).Content
  # Kept for the rest of this Refresh: the collection log and the bank both need the GE prices
  if ($script:Prefetch -is [hashtable]) { $script:Prefetch[$url] = $body }
  $body
}
# PSCustomObject -> hashtable: property lookups on big parsed JSON objects are very slow in PS 5.1
function ConvertTo-Hash($obj) {
  $h = @{}
  if ($obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
  return $h
}

# A JSON file as a hashtable, parsed once and kept until the file changes (icon lookups ask for the same file
# hundreds of times per Refresh). $null when the file doesn't exist.
$script:JsonHashCache = @{}
function Get-JsonHashCached([string]$file) {
  if (-not (Test-Path $file)) { return $null }
  $stamp = (Get-Item $file).LastWriteTimeUtc.Ticks
  $c = $script:JsonHashCache[$file]
  if (-not $c -or $c.stamp -ne $stamp) {
    $c = @{ stamp = $stamp; hash = (ConvertTo-Hash ([IO.File]::ReadAllText($file, $Utf8) | ConvertFrom-Json)) }
    $script:JsonHashCache[$file] = $c
  }
  return $c.hash
}

# Every item id in the log (owned or not), so missing items can be shown faded
function Get-AllLogIds {
  $cats = Read-ClogFile "categories.json"
  if (-not $cats) { return @() }
  $ids = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($group in ($cats | ConvertFrom-Json).PSObject.Properties) {
    if ($group.Name -eq "names") { continue }   # page key -> page name, no ids
    foreach ($cat in $group.Value.PSObject.Properties) { foreach ($id in $cat.Value) { [void]$ids.Add("$id") } }
  }
  return @($ids)
}

# One GE price from the wiki price API's buy (high) and sell (low) side: normally their average. On thin items
# one side can be a silly one-off trade (e.g. Pyrophosphite's last instant-buy was 1,000,000 while it
# sells for ~300-1,000, so "Price moves today" showed +50,000%). When the sides are more than $PriceSpread
# times apart only one is used: the one closer to $ref (a recent price), else the one with the bigger weight
# (trade time for /latest = the newer trade, volume for /1h = the busier side).
$PriceSpread = 3
function Get-GePrice($h, $l, $hw, $lw, $ref) {
  if (-not $h) { return $l }
  if (-not $l) { return $h }
  if ([math]::Max($h, $l) -le $PriceSpread * [math]::Min($h, $l)) { return [long](($h + $l) / 2) }
  if ($ref -gt 0) { if ([math]::Abs([math]::Log($h / $ref)) -lt [math]::Abs([math]::Log($l / $ref))) { return $h } else { return $l } }
  if ($hw -gt $lw) { return $h } else { return $l }
}

# Collection log items you've obtained (count > 0 in the latest saved log), as id strings
function Get-LoggedIds {
  $f = Join-Path $ClogDir "history.jsonl"
  if (-not (Test-Path $f)) { return @() }
  $last = [IO.File]::ReadAllLines($f, $Utf8) | Where-Object { $_.Trim() } | Select-Object -Last 1
  $items = [regex]::Match([string]$last, '"items":\{(.*)\}').Groups[1].Value
  return @([regex]::Matches($items, '"(\d+)":\[(\d+)') | Where-Object { [long]$_.Groups[2].Value -gt 0 } | ForEach-Object { $_.Groups[1].Value })
}

# GE prices of the log items you've obtained (no prices for items you don't have) from the OSRS
# Wiki price API (one request; it sends every item, the rest is dropped), used for the item value tiers. Stored
# locally; fetched again only when a log item is new or its count went up (or the file is missing). Untradeables
# (pets, ...) have no price.
# data\clog\prices.json  {"t":ISO,"prices":{"<id>":gp}}  gp = Get-GePrice of the latest buy/sell
function Update-ClogPrices([bool]$logChanged, $logIds = (Get-LoggedIds)) {
  $f = Join-Path $ClogDir "prices.json"
  if ((Test-Path $f) -and -not $logChanged) { return "prices stored" }
  $all = ConvertTo-Hash (Get-Web "https://prices.runescape.wiki/api/v1/osrs/latest" | ConvertFrom-Json).data
  $resetFile = Join-Path $DataDir "bank\prices-reset.json"
  $ref = if (Test-Path $resetFile) { ConvertTo-Hash ([IO.File]::ReadAllText($resetFile, $Utf8) | ConvertFrom-Json).prices } else { @{} }
  $prices = [ordered]@{}
  foreach ($id in $logIds) {
    $p = $all[$id]
    if (-not $p) { continue }
    $g = Get-GePrice $p.high $p.low $p.highTime $p.lowTime $ref[$id]
    if ($g) { $prices[$id] = [long]$g }
  }
  Save-ClogFile "prices.json" ([ordered]@{ t = (Get-Date).ToUniversalTime().ToString("o"); prices = $prices } | ConvertTo-Json -Compress)
  return "prices updated ($($prices.Count) items)"
}

# Looks up the wiki image file for item ids we haven't seen, 40 per request
function Update-ClogImages($ids) {
  $map = @{}
  $existing = Read-ClogFile "images.json"
  if ($existing) { ($existing | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $map[$_.Name] = $_.Value } }
  $todo = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($id in $ids) { if (-not $map.ContainsKey("$id")) { [void]$todo.Add("$id") } }
  $todo = @($todo)
  if (-not $todo.Count) { return }
  for ($i = 0; $i -lt $todo.Count; $i += 40) {
    $batch = @($todo[$i..([Math]::Min($i + 39, $todo.Count - 1))])
    $or = ($batch | ForEach-Object { "{'item_id','$_'}" }) -join ","
    $q = "bucket('infobox_item').select('item_id','image').where(bucket.Or($or)).limit(500).run()"
    $res = Get-Web "${WikiApi}?action=bucket&format=json&query=$([uri]::EscapeDataString($q))" | ConvertFrom-Json
    foreach ($row in $res.bucket) {
      $file = (@($row.image)[0]) -replace '^File:', ''
      if (-not $file) { continue }
      foreach ($id in @($row.item_id)) {
        if ($batch -contains "$id" -and -not $map.ContainsKey("$id")) { $map["$id"] = $file }
      }
    }
    Start-Sleep -Milliseconds 400
  }
  # Not found by id on the wiki: try "<item name>.png"
  $names = Read-ClogFile "items.json"
  if ($names) {
    $known = ($names | ConvertFrom-Json).items
    foreach ($id in $todo) { if (-not $map.ContainsKey($id) -and $known.$id) { $map[$id] = "$($known.$id).png" } }
  }
  Save-ClogFile "images.json" ($map | ConvertTo-Json -Compress)
}

# icons\item\<id>.png: downloaded once from the wiki, outlined, then served from disk
function Get-ItemIcon([string]$id) {
  $dir  = Join-Path $Root "icons\item"
  $file = Join-Path $dir "$id.png"
  if (Test-Path $file) { return [IO.File]::ReadAllBytes($file) }
  # Tried once per server run: the server answers one request at a time, so retrying a missing icon
  # on every page load held up all the other icons
  if ($script:NoIcon -and $script:NoIcon.Contains("item/$id")) { return $null }
  if ($script:NoIcon) { [void]$script:NoIcon.Add("item/$id") }
  $images = Get-JsonHashCached (Join-Path $ClogDir "images.json")
  $name = if ($images) { $images[$id] }
  if (-not $name -and (Get-Command Get-BankImage -ErrorAction SilentlyContinue)) { $name = Get-BankImage $id }   # bank items
  if (-not $name) { return $null }
  # Normally never reached: tools\fetch-all-icons.ps1 saves every item icon. Special:Redirect follows renamed files.
  $url = "https://oldschool.runescape.wiki/w/Special:Redirect/file/" + [uri]::EscapeDataString(($name -replace ' ', '_'))
  $ProgressPreference = "SilentlyContinue"
  try { $res = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -UserAgent $ClogUA }
  catch { if (Get-Command Add-NoIcon -ErrorAction SilentlyContinue) { Add-NoIcon "item/$id" $_ }; return $null }
  if ($script:NoIcon) { [void]$script:NoIcon.Remove("item/$id") }
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
  $bytes = Add-IconOutline $res.Content
  [IO.File]::WriteAllBytes($file, $bytes)
  return $bytes
}

# GET /api/clog: {"history":[...], "names":{id:name}, "categories":{"names":{page:name}, tab:{page:[ids]}}}
function Get-ClogJson {
  $histFile = Join-Path $ClogDir "history.jsonl"
  # [string[]]: an empty list must stay a list, or Join fails on a fresh install (no history yet)
  $lines = [string[]]@(if (Test-Path $histFile) { [IO.File]::ReadAllText($histFile, $Utf8).Split([char[]]"`r`n", [StringSplitOptions]::RemoveEmptyEntries) })
  $names = Read-ClogFile "items.json"; if (-not $names) { $names = '{"items":{}}' }
  $cats  = Read-ClogFile "categories.json"; if (-not $cats) { $cats = "{}" }
  $prices = Read-ClogFile "prices.json"; if (-not $prices) { $prices = "null" }
  return "{""history"":[" + [string]::Join(",", $lines) + "],""names"":" + $names + ",""categories"":" + $cats + ",""prices"":" + $prices + "}"
}
