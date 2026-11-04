# The collection log's layout from the OSRS Wiki: its tabs (Bosses, Raids, Clues, Minigames, Other), the pages in each
# tab and the items on each page, in the game's order, plus every log item's name. Writes data\clog\categories.json and
# data\clog\items.json. Run once, and again only when Jagex adds collection log items:
#   powershell -ExecutionPolicy Bypass -File tools\fetch-clog-layout.ps1
# Sources (OSRS Wiki only): the "Collection log" page (==Tab== / ===Page=== sections, items as {{plink|Name}}), the
# wiki's collection_log_source bucket (name -> item id, all 1,700+ log items) and the wiki price API's item list /
# infobox_item bucket for names (the same lookup the bank uses).
#
# categories.json  {"names": {"<key>": "<Page name>"}, "<tab key>": {"<key>": [ids in log order]}, ...}
#                  key = the page name in lowercase, & -> and, apostrophes dropped, other runs -> "_" (app.js slug())
# items.json       {"items": {"<id>": "<item name>"}}
$Root = Split-Path $PSScriptRoot -Parent
$DataDir = Join-Path $Root "data"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Player = ""
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $Root "clog.ps1")   # Get-Web, $WikiApi, $ClogDir, Save-ClogFile, ConvertTo-Hash
. (Join-Path $Root "bank.ps1")   # Update-BankItems, Read-BankHash: wiki item names by id
$ErrorActionPreference = "Stop"

# Log page links whose item the wiki lists under another name
$Aliases = @{
  "uncharged trident"    = "trident of the seas#uncharged"
  "agility arena ticket" = "agility arena ticket (discontinued)"
  "trident of the seas"  = "trident of the seas#charged"   # Kraken; the cave kraken's one is "Uncharged trident"
  "guthix d'hide shield" = "23188"                         # the wiki's bucket names this id "Mithril keel#Sloop"
}
$slug = { param($s) (($s.ToLowerInvariant() -replace '&', 'and' -replace "['’]", '') -replace '[^a-z0-9]+', '_').Trim('_') }

# 1. Every log item: wiki name -> ids (several items can share a base name, e.g. "Pet dark core#Dark core")
$q = "bucket('collection_log_source').select('item_id','item_name').limit(5000).run()"
$rows = @((Get-Web "${WikiApi}?action=bucket&format=json&query=$([uri]::EscapeDataString($q))" | ConvertFrom-Json).bucket)
if ($rows.Count -lt 1000) { throw "The wiki listed only $($rows.Count) collection log items; nothing changed." }
$byName = @{}; $byBase = @{}
foreach ($r in $rows) {
  $full = ([string]$r.item_name).ToLowerInvariant(); $base = ($full -split '#')[0]
  if (-not $byName.ContainsKey($full)) { $byName[$full] = New-Object System.Collections.Generic.List[int] }; $byName[$full].Add([int]$r.item_id)
  if (-not $byBase.ContainsKey($base)) { $byBase[$base] = New-Object System.Collections.Generic.List[int] }; $byBase[$base].Add([int]$r.item_id)
}

# 2. The page: tabs, pages, items
$text = (Get-Web "${WikiApi}?action=parse&page=Collection_log&prop=wikitext&format=json" | ConvertFrom-Json).parse.wikitext.'*'
$tabs = "Bosses", "Raids", "Clues", "Minigames", "Other"
$out = [ordered]@{ names = [ordered]@{} }
$tab = $null; $page = $null; $used = New-Object 'System.Collections.Generic.HashSet[int]'; $unmatched = @()
foreach ($line in $text -split "`n") {
  if ($line -match '^==([^=].*?)==\s*$') {
    $name = $Matches[1].Trim(); $tab = if ($tabs -contains $name) { & $slug $name } else { $null }; $page = $null
    if ($tab) { $out[$tab] = [ordered]@{} }
    continue
  }
  if (-not $tab) { continue }
  if ($line -match '^===([^=].*?)===\s*$') {
    $page = & $slug $Matches[1].Trim()
    $out.names[$page] = $Matches[1].Trim()
    $out[$tab][$page] = New-Object System.Collections.Generic.List[int]
    continue
  }
  if (-not $page) { continue }
  foreach ($m in [regex]::Matches($line, '\{\{plink\|([^}]+)\}\}')) {
    $parts = $m.Groups[1].Value -split '\|'
    $n = $parts[0].Trim().ToLowerInvariant()
    # Names to try, most exact first: the shown text (txt=), the link, "Name (variant)" as the wiki's "Name#Variant",
    # a few links whose item has another name, then the picture (pic=)
    $tries = New-Object System.Collections.Generic.List[string]
    if ($Aliases.ContainsKey($n)) { $tries.Add($Aliases[$n]) }
    $tries.Add($n)
    if ($n -match '^(.*?)\s*\((.+)\)$') {
      $b = $Matches[1]; $v = $Matches[2]
      $tries.Add("$b#$v"); $tries.Add("$b#($v)"); if ($v -eq "u") { $tries.Add("$b#uncharged") }
    }
    foreach ($p in $parts[1..9]) { if ($p -match '^\s*(txt|pic)\s*=\s*(.+)$') { $tries.Add($Matches[2].Trim().ToLowerInvariant()) } }
    $cands = $null
    foreach ($t in $tries) {
      if ($t -match '^\d+$') { $cands = , [int]$t; break }
      if ($byName.ContainsKey($t)) { $cands = $byName[$t]; break }
    }
    if (-not $cands) { foreach ($t in $tries) { $b = ($t -split '#')[0]; if ($byBase.ContainsKey($b)) { $cands = $byBase[$b]; break } } }
    # Ids already placed on this page are skipped (several variants of one name, in order)
    $id = if ($cands) { @($cands | Where-Object { -not $out[$tab][$page].Contains($_) })[0] }
    if ($id) { $out[$tab][$page].Add($id); [void]$used.Add($id) } else { $unmatched += "$($out.names[$page]): $($m.Groups[1].Value)" }
  }
}
$pages = @($out.Keys | Where-Object { $_ -ne "names" } | ForEach-Object { $out[$_].Count } | Measure-Object -Sum).Sum
$missing = @($rows | Where-Object { -not $used.Contains([int]$_.item_id) })
"Layout: $(@($out.Keys).Count - 1) tabs, $pages pages, $($used.Count) of $($rows.Count) log items placed"
if ($unmatched) { "Not matched to an item id ($($unmatched.Count)): " + ($unmatched -join "; ") }
if ($missing) { "Log items not on any page ($($missing.Count)): " + (($missing | ForEach-Object { "$($_.item_name) ($($_.item_id))" }) -join "; ") }
if ($used.Count -lt 0.98 * $rows.Count) { throw "Too few items placed; nothing changed." }

# 3. Names: the wiki's item names by id (tradeables: price API list; others: infobox_item), as the bank does it
$ids = @($rows | ForEach-Object { "$($_.item_id)" })
if (-not (Test-Path $BankDir)) { New-Item -ItemType Directory $BankDir | Out-Null }
[void](Update-BankItems $ids)
$known = Read-BankHash "items.json"
$names = [ordered]@{}
foreach ($r in $rows) { $id = "$($r.item_id)"; $names[$id] = if ($known[$id] -and @($known[$id])[0] -notmatch '^Item \d+$') { @($known[$id])[0] } else { ([string]$r.item_name -split '#')[0] } }

if (-not (Test-Path $ClogDir)) { New-Item -ItemType Directory $ClogDir | Out-Null }
Save-ClogFile "categories.json" ($out | ConvertTo-Json -Compress -Depth 5)
Save-ClogFile "items.json" ([ordered]@{ items = $names } | ConvertTo-Json -Compress)
"Saved data\clog\categories.json and items.json ($($names.Count) names)"
