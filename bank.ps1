# Bank contents for the page. They come only from the OSRS Data Sync RuneLite plugin
# "OSRS Data Sync" (plugin.ps1 Get-PluginContainers: bank as last seen open + what you wear and carry).
# Nothing is uploaded anywhere. Dot-sourced by server.ps1 after clog.ps1 (needs $DataDir, $Player, $Utf8, Get-Web,
# ConvertTo-Hash). Read on Refresh.
#
# data\bank\history.jsonl  one line per change: {"t":read ISO,"saved":"<bank time>","src":"plugin",
#                          "items":[[id,qty],...] (bank order, no placeholders), "worn":[[id,qty]],"carried":[[id,qty]],
#                          "ge":[{"item":[id,total],"done":n,"price":gp,"spent":gp,"state":"SELLING"}]}  (last field)
#                          Older lines have no "ge" and carry other src tags (app.js SAVE_KIND reads them; never rewritten).
# data\bank\items.json     id -> [name, wiki image file]   (looked up when an id is new)
# EVERY price file below holds only YOUR items (Get-BankPriceIds: bank ever, logged, loot + valuation parts).
# The wiki price API always sends every item in one response; the rest is never saved.
# data\bank\prices.json    {"t":ISO,"owned":true,"prices":{"<id>":gp}}  (once a day; fallback for ids missing elsewhere)
# data\bank\prices-live.json  {"t":ISO,"prices":{..}}     GE prices now (every Refresh): today's bank value, "Price moves"
# data\bank\prices-saves.jsonl {"t":<history line t>,"prices":{..}}  GE prices when each save was made (value graph)
# data\bank\prices-reset.json {"t":ISO,"reset":unix s,"prices":{..}}  the hour before today's 00:00 UTC reset
# data\bank\prices-days.json  {"<UTC date>":{..}}  each past day's prices.json (value graph at the prices of the time)
#
# Smart values for items without a GE price (the page uses the first that applies):
# data\bank\mapping.json   RuneLite's own untradeable -> tradeable list (tools\fetch-item-mapping.ps1, once):
#                          {"map":{"<id>":[[tradeable id, qty], ...]}}  several entries are added up
# data\bank\derived.json   worked out here for new ids: {"<id>": null | {"via":"doses"|"charges"|"recipe",
#                          "options":[[[part id, qty], ...], ...]}}  null = nothing found / has its own price.
#                          doses: Prayer potion(2) = 2/4 of Prayer potion(4). charges: same price as the
#                          charged version on the GE. recipe: OSRS Wiki recipe's tradeable materials (one level
#                          deeper for untradeable materials); the page uses the cheapest option that has a value.

$BankDir = Join-Path $DataDir "bank"
$PricesUrl = "https://prices.runescape.wiki/api/v1/osrs/latest"
$GeItemsUrl = "https://prices.runescape.wiki/api/v1/osrs/mapping"
$PricesHourUrl = "https://prices.runescape.wiki/api/v1/osrs/1h?timestamp="
# Coins and platinum tokens have no GE price
$FixedPrices = @{ "995" = 1; "13204" = 1000 }

function Read-BankFile([string]$name) {
  $f = Join-Path $BankDir $name
  if (Test-Path $f) { return [IO.File]::ReadAllText($f, $Utf8) }
  return $null
}
function Save-BankFile([string]$name, [string]$text) {
  [IO.File]::WriteAllText((Join-Path $BankDir $name), $text, $Utf8)
}

$BankFiller = 20594
# Item list from the plugin (@{id; qty} objects) -> @(@(id, qty), ...), same ids added up, bank fillers dropped
function ConvertFrom-ItemList($list) {
  $out = [ordered]@{}
  foreach ($it in @($list)) {
    if (-not $it -or $it.id -eq $BankFiller) { continue }
    $id = "$($it.id)"
    $out[$id] = [long]$out[$id] + [long]$it.qty
  }
  # unary comma: a one-item list would otherwise unroll into [id, qty]
  return , @(foreach ($k in $out.Keys) { if ($out[$k] -gt 0) { , @([int]$k, $out[$k]) } })
}

# Called on Refresh; returns a short status message
function Update-Bank {
  if (-not (Test-Path $BankDir)) { New-Item -ItemType Directory $BankDir | Out-Null }
  $histFile = Join-Path $BankDir "history.jsonl"
  $prev = $null
  if (Test-Path $histFile) {
    $last = [IO.File]::ReadAllLines($histFile, $Utf8) | Where-Object { $_.Trim() } | Select-Object -Last 1
    if ($last) { $prev = $last | ConvertFrom-Json }
  }

  # The plugin's containers.json: the bank as last seen open, and what you wear / carry (kept after logout too;
  # the plugin already counts noted items as the item)
  $plug = Get-PluginContainers
  if (-not $plug) { return "Bank: nothing from OSRS Data Sync yet (log in with the plugin on and open your bank once)" }
  $src = "plugin"
  $items = ConvertFrom-ItemList $plug.bank
  $saved = if ($plug.bankAt) { [DateTimeOffset]::FromUnixTimeMilliseconds($plug.bankAt).LocalDateTime.ToString("HH:mm:ss, d MMM yyyy") } else { "before " + $plug.updated.ToLocalTime().ToString("HH:mm:ss, d MMM yyyy") }
  $hasOut = $true
  $worn = ConvertFrom-ItemList $plug.equipment
  $carried = ConvertFrom-ItemList $plug.inventory
  $pouch = if ($null -ne $plug.runePouch) { ConvertFrom-ItemList $plug.runePouch } else { $null }

  # Written by hand: PS 5.1's ConvertTo-Json turns arrays that went through a pipeline into {"value":..,"Count":..}
  $toJson = { param($list) "[" + ((@(foreach ($p in @($list)) { if ($p) { "[$([long]$p[0]),$([long]$p[1])]" } })) -join ",") + "]" }
  # Offers are part of what's owned (the page counts them), so a change is a new line. No offers = same as a line without "ge"
  $geText = if ($plug.ge -and $plug.ge -ne "[]") { $plug.ge } else { "" }
  $prevGe = [regex]::Match([string]$last, ',"ge":(\[.*\])\}$').Groups[1].Value
  if ($prevGe -eq "[]") { $prevGe = "" }
  $now = "$(& $toJson $items)|$(& $toJson $worn)|$(& $toJson $carried)|$hasOut|$(if ($null -ne $pouch) { & $toJson $pouch })|$geText"
  $before = if ($prev) { "$(& $toJson $prev.items)|$(& $toJson $prev.worn)|$(& $toJson $prev.carried)|$([bool]$prev.PSObject.Properties['worn'])|$(if ($prev.PSObject.Properties['pouch']) { & $toJson $prev.pouch })|$prevGe" }
  $changed = $now -ne $before
  $status = "no change"
  $lineT = $null
  if ($changed) {
    $lineT = (Get-Date).ToUniversalTime().ToString("o")
    # Rune pouch (the game keeps it out of every item list; the plugin reads it), when the plugin sent it
    $pouchJson = if ($null -ne $pouch) { ',"pouch":' + (& $toJson $pouch) } else { "" }
    $geJson = if ($null -ne $plug.ge) { ',"ge":' + $plug.ge } else { "" }
    $line = "{""t"":""$lineT"",""saved"":$(ConvertTo-Json $saved),""src"":""$src""," +
      """items"":$(& $toJson $items),""worn"":$(& $toJson $worn),""carried"":$(& $toJson $carried)$pouchJson$geJson}"
    [IO.File]::AppendAllText($histFile, $line + "`n", $Utf8)
    $status = "saved ($($items.Count) items, $($worn.Count) worn, $($carried.Count) carried)"
  }
  # When the gear was last known (lines are only written on change, so this lives apart). "seen" = when the
  # plugin last wrote its file, i.e. the gear as of then; RuneLite may be closed now.
  $inv = "[" + ((@(foreach ($s in @($plug.invLayout)) { if ($s) { "[$($s[0]),$($s[1]),$($s[2])]" } })) -join ",") + "]"
  Save-BankFile "gear.json" "{""t"":""$((Get-Date).ToUniversalTime().ToString("o"))"",""src"":""plugin"",""seen"":""$($plug.updated.ToUniversalTime().ToString("o"))"",""inv"":$inv}"


  # Items that just left the bank keep a price too, so the page can show what you spent/sold
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($list in $items, $worn, $carried, @($prev.items), @($prev.worn), @($prev.carried)) {
    foreach ($b in @($list)) { if ($b) { [void]$set.Add("$($b[0])") } }
  }
  $ids = @($set)
  $names = try { Update-BankItems $ids } catch { "names unavailable: $($_.Exception.Message)" }
  $values = try { Update-BankDerived $ids } catch { "smart values unavailable: $($_.Exception.Message)" }
  # The parts untradeables are valued by need a name (tooltips) and a price too
  $parts = @(Get-BankParts $ids | Where-Object { -not $set.Contains($_) })
  if ($parts.Count) { try { [void](Update-BankItems $parts) } catch { } }
  # Items in Grand Exchange offers may never have been owned: the page needs their name too
  $geIds = @(Get-BankGeIds | Where-Object { -not $set.Contains($_) })
  if ($geIds.Count) { try { [void](Update-BankItems $geIds) } catch { } }
  $live = try { Update-BankLivePrices } catch { Write-Host "Live prices unavailable: $($_.Exception.Message)"; $null }
  $prices = try { Update-BankPrices $live } catch { "prices unavailable: $($_.Exception.Message)" }
  $past = try { Update-BankPastPrices } catch { "past prices unavailable: $($_.Exception.Message)" }
  $dayPrices = try { Update-BankDayPrices } catch { "day prices unavailable: $($_.Exception.Message)" }
  $savePrices = try { Update-BankSavePrices $lineT $live } catch { "save prices unavailable: $($_.Exception.Message)" }
  $wornIds = @(foreach ($list in $worn, @($prev.worn)) { foreach ($w in @($list)) { if ($w) { "$($w[0])" } } })
  try { Update-BankSlots $wornIds } catch { }
  return "Bank (OSRS Data Sync): $status - $names - $values - $prices - $past - $dayPrices - $savePrices"
}

# Equipment slot (head, cape, neck, ammo, weapon, 2h, body, shield, legs, hands, feet, ring) of worn items, for the
# page's equipment screen. The plugin sends no slots, so: wiki infobox_item (id -> page) then infobox_bonuses
# (page -> slot). Only ids new to slots.json are looked up; "" = not found, not retried.
function Update-BankSlots($ids) {
  $map = Read-BankHash "slots.json"
  $todo = @($ids | Where-Object { $_ -and -not $map.ContainsKey($_) } | Sort-Object -Unique)
  if (-not $todo.Count) { return }
  $or = ($todo | ForEach-Object { "{'item_id','$_'}" }) -join ","
  $q = "bucket('infobox_item').select('item_id','page_name').where(bucket.Or($or)).limit(500).run()"
  $pages = @{}
  foreach ($row in (Get-Web "${WikiApi}?action=bucket&format=json&query=$([uri]::EscapeDataString($q))" | ConvertFrom-Json).bucket) {
    foreach ($id in @($row.item_id)) { if ($todo -contains "$id") { $pages["$id"] = [string]$row.page_name } }
  }
  $slotOf = @{}
  $names = @($pages.Values | Sort-Object -Unique)
  if ($names.Count) {
    $or = ($names | ForEach-Object { "{'page_name','$($_ -replace "'", "\'")'}" }) -join ","
    $q = "bucket('infobox_bonuses').select('page_name','equipment_slot').where(bucket.Or($or)).limit(500).run()"
    foreach ($row in (Get-Web "${WikiApi}?action=bucket&format=json&query=$([uri]::EscapeDataString($q))" | ConvertFrom-Json).bucket) {
      if ($row.equipment_slot -and -not $slotOf.ContainsKey($row.page_name)) { $slotOf[$row.page_name] = [string]$row.equipment_slot }
    }
  }
  foreach ($id in $todo) { $map[$id] = if ($pages[$id] -and $slotOf[$pages[$id]]) { $slotOf[$pages[$id]] } else { "" } }
  Save-BankFile "slots.json" ($map | ConvertTo-Json -Compress)
}

function Read-BankHash([string]$name, [string]$prop) {
  $text = Read-BankFile $name
  if (-not $text) { return @{} }
  $obj = $text | ConvertFrom-Json
  if ($prop) { $obj = $obj.$prop }
  return ConvertTo-Hash $obj
}

# Every tradeable part id that the bank's untradeables are valued by (RuneLite list + derived.json)
function Get-BankParts($ids) {
  $rl = Read-BankHash "mapping.json" "map"
  $derived = Read-BankHash "derived.json"
  $out = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($id in $ids) {
    foreach ($m in @($rl[$id])) { if ($m) { [void]$out.Add("$($m[0])") } }
    $d = $derived[$id]
    if ($d) { foreach ($opt in @($d.options)) { foreach ($p in @($opt)) { [void]$out.Add("$($p[0])") } } }
  }
  return @($out)
}

# Works out smart values (see the top of this file) for ids not looked at before. Wiki requests only
# happen when the bank has an id that is new to derived.json.
function Update-BankDerived($ids) {
  $derived = Read-BankHash "derived.json"
  $rl = Read-BankHash "mapping.json" "map"
  $names = Read-BankHash "items.json"
  $todo = @($ids | Where-Object { -not $derived.ContainsKey($_) -and -not $rl.ContainsKey($_) -and $names[$_] })
  if (-not $todo.Count) { return "smart values stored" }

  # Every tradeable item (the GE's item list): ids, and lower-case name -> id
  $tradeable = New-Object 'System.Collections.Generic.HashSet[string]'
  $byName = @{}
  foreach ($it in (Get-Web $GeItemsUrl | ConvertFrom-Json)) {
    [void]$tradeable.Add("$($it.id)")
    $k = $it.name.ToLower()
    if (-not $byName.ContainsKey($k)) { $byName[$k] = "$($it.id)" }
  }

  $recipeFor = @{}   # item name -> id, for items still to look up in the wiki recipes
  $found = 0
  foreach ($id in $todo) {
    $name = [string]$names[$id][0]
    $derived[$id] = $null
    # Doses / charges: "Super restore(2)", "Slayer ring (5)" -> the same item with a GE price
    if ($name -match '^(.*?)\s?\((\d+)\)$') {
      $base = $Matches[1]; $n = [int]$Matches[2]
      $sib = @(foreach ($k in 1..10) {
        if ($k -eq $n) { continue }
        foreach ($cand in "$base($k)", "$base ($k)") { $sid = $byName[$cand.ToLower()]; if ($sid) { ,@($k, $sid); break } }
      })
      if ($sib.Count) {
        $max = ($sib | ForEach-Object { $_[0] } | Measure-Object -Maximum).Maximum
        # Potions (up to 4 doses): a share of the full potion. Jewellery charges, or more charges than any
        # GE version has (Amulet of glory(6)): the nearest charged version's price as it is.
        if ($max -le 4 -and $n -lt $max) {
          $best = $sib | Where-Object { $_[0] -eq $max } | Select-Object -First 1
          $derived[$id] = @{ via = "doses"; options = @(, @(, @([int]$best[1], [math]::Round($n / $best[0], 4)))) }
        } else {
          $best = $sib | Sort-Object { [math]::Abs($_[0] - $n) } | Select-Object -First 1
          $derived[$id] = @{ via = "charges"; options = @(, @(, @([int]$best[1], 1))) }
        }
        $found++
        continue
      }
    }
    if ($tradeable.Contains($id)) { continue }   # has (or had) its own GE price
    $recipeFor[$name] = $id
  }

  # Wiki recipes: { output name (lower) -> list of options, each a list of @(material name, qty per item) }
  $getRecipes = {
    param([string[]]$pageNames)
    $out = @{}
    for ($i = 0; $i -lt $pageNames.Count; $i += 25) {
      $batch = @($pageNames[$i..([Math]::Min($i + 24, $pageNames.Count - 1))])
      $or = ($batch | ForEach-Object { "{'page_name','" + $_.Replace('\', '\\').Replace("'", "\'") + "'}" }) -join ","
      $q = "bucket('recipe').select('page_name','production_json').where(bucket.Or($or)).limit(500).run()"
      $res = Get-Web "${WikiApi}?action=bucket&format=json&query=$([uri]::EscapeDataString($q))" | ConvertFrom-Json
      foreach ($row in $res.bucket) {
        $p = try { $row.production_json | ConvertFrom-Json } catch { $null }
        if (-not $p -or -not $p.output.name -or -not @($p.materials).Count) { continue }
        $outQty = [math]::Max(1, [double]("0" + $p.output.quantity))
        $mats = @(foreach ($m in @($p.materials)) { ,@([string]$m.name, ([double]("0" + $m.quantity) / $outQty)) })
        $key = $p.output.name.ToLower()
        if (-not $out.ContainsKey($key)) { $out[$key] = New-Object System.Collections.ArrayList }
        [void]$out[$key].Add($mats)
      }
      Start-Sleep -Milliseconds 400
    }
    return $out
  }
  if ($recipeFor.Count) {
    $recipes = & $getRecipes @($recipeFor.Keys)
    # Untradeable materials: one level deeper (e.g. a hilt that is itself made from tradeables)
    $deeper = @($recipes.Values | ForEach-Object { $_ } | ForEach-Object { $_ } | ForEach-Object { $_[0] } |
      Where-Object { -not $byName.ContainsKey($_.ToLower()) } | Sort-Object -Unique)
    $sub = if ($deeper.Count) { & $getRecipes $deeper } else { @{} }
    foreach ($name in $recipeFor.Keys) {
      $opts = $recipes[$name.ToLower()]
      if (-not $opts) { continue }
      $options = @(foreach ($mats in $opts) {
        $parts = @(foreach ($m in $mats) {
          $mid = $byName[$m[0].ToLower()]
          if ($mid) { ,@([int]$mid, $m[1]); continue }
          # Untradeable material: use its own recipe's tradeable materials (first recipe that has some)
          if (-not $sub.ContainsKey($m[0].ToLower())) { continue }
          foreach ($smats in @($sub[$m[0].ToLower()])) {
            $sp = @(foreach ($s in @($smats)) { $sid = $byName[$s[0].ToLower()]; if ($sid) { ,@([int]$sid, ($s[1] * $m[1])) } })
            if ($sp.Count) { $sp; break }
          }
        })
        if ($parts.Count) { , $parts }
      })
      if ($options.Count) { $derived[$recipeFor[$name]] = @{ via = "recipe"; options = $options }; $found++ }
    }
  }
  Save-BankFile "derived.json" ($derived | ConvertTo-Json -Compress -Depth 6)
  return "smart values: $found of $($todo.Count) new items valued by their parts"
}

# Item names + wiki image files, only for ids we haven't looked up before. Tradeables come from the
# wiki price API's item list (one request); the rest (untradeables) from the wiki's item infobox data.
function Update-BankItems($ids) {
  $map = @{}
  $existing = Read-BankFile "items.json"
  if ($existing) { $map = ConvertTo-Hash ($existing | ConvertFrom-Json) }
  $todo = @($ids | Where-Object { -not $map.ContainsKey($_) } | Sort-Object -Unique)
  if (-not $todo.Count) { return "names stored" }

  $wanted = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($id in $todo) { [void]$wanted.Add($id) }
  foreach ($it in (Get-Web "https://prices.runescape.wiki/api/v1/osrs/mapping" | ConvertFrom-Json)) {
    if ($wanted.Remove("$($it.id)")) { $map["$($it.id)"] = @($it.name, $it.icon) }
  }
  $rest = @($wanted)
  for ($i = 0; $i -lt $rest.Count; $i += 40) {
    $batch = @($rest[$i..([Math]::Min($i + 39, $rest.Count - 1))])
    $or = ($batch | ForEach-Object { "{'item_id','$_'}" }) -join ","
    $q = "bucket('infobox_item').select('item_id','item_name','image').where(bucket.Or($or)).limit(500).run()"
    $res = Get-Web "${WikiApi}?action=bucket&format=json&query=$([uri]::EscapeDataString($q))" | ConvertFrom-Json
    foreach ($row in $res.bucket) {
      # Stackables list one picture per stack size; the last is the biggest pile (coins, runes...)
      $file = (@($row.image)[-1]) -replace '^File:', ''
      foreach ($id in @($row.item_id)) {
        if ($batch -contains "$id" -and -not $map.ContainsKey("$id")) { $map["$id"] = @([string]$row.item_name, $file) }
      }
    }
    Start-Sleep -Milliseconds 400
  }
  # Not on the wiki under that id: remember it so it isn't looked up again every Refresh
  foreach ($id in $todo) { if (-not $map.ContainsKey($id)) { $map[$id] = @("Item $id", "") } }
  Save-BankFile "items.json" ($map | ConvertTo-Json -Compress)
  return "names updated ($($todo.Count) new)"
}

# A price map trimmed to your items (Get-BankPriceIds)
function Select-OwnedPrices($prices, $ids = (Get-BankPriceIds)) {
  $out = [ordered]@{}
  foreach ($id in $ids) { if ($prices.Contains($id)) { $out[$id] = $prices[$id] } }
  return $out
}

# GE prices of your items (same source and averaging as the collection log prices). Set at most once a day: on
# the first Refresh after the daily reset (00:00 UTC). An item new to the bank later
# that day gets its price from the same Refresh's live download ($live), so it never needs a download of its own.
# "owned" marks a file trimmed to your items (older files had every GE item, "all").
function Update-BankPrices($live) {
  $ids = Get-BankPriceIds
  $old = Read-BankFile "prices.json"
  if ($old) {
    $o = $old | ConvertFrom-Json
    $isToday = [datetime]::Parse($o.t).ToUniversalTime() -ge (Get-Date).ToUniversalTime().Date
    if ($o.owned -and $isToday) {
      $have = ConvertTo-Hash $o.prices
      $added = 0
      if ($live) { foreach ($id in $ids) { if (-not $have.ContainsKey($id) -and $live.Contains($id)) { $have[$id] = $live[$id]; $added++ } } }
      if (-not $added) { return "prices stored (today's)" }
      Save-BankFile "prices.json" ([ordered]@{ t = $o.t; owned = $true; prices = $have } | ConvertTo-Json -Compress)
      return "prices stored (today's, $added new items added)"
    }
    # Yesterday's (or the last Refresh day's) prices are kept for the value graph before they're replaced
    if (($o.all -or $o.owned) -and -not $isToday) { Save-BankDayPrices ([datetime]::Parse($o.t).ToUniversalTime().ToString("yyyy-MM-dd")) (ConvertTo-Hash $o.prices) }
  }
  $all = if ($live) { $live } else { ConvertTo-PriceMap (Get-Web $PricesUrl | ConvertFrom-Json).data "high" "low" "highTime" "lowTime" }
  $prices = Select-OwnedPrices $all $ids
  Save-BankFile "prices.json" ([ordered]@{ t = (Get-Date).ToUniversalTime().ToString("o"); owned = $true; prices = $prices } | ConvertTo-Json -Compress)
  return "prices updated ($($prices.Count) items)"
}

# Wiki price API data -> {"<id>": gp}: Get-GePrice of the high and low price (weights + $ref for when they
# disagree, see clog.ps1), + coins/tokens
function ConvertTo-PriceMap($data, [string]$hi, [string]$lo, [string]$hiW, [string]$loW, $ref = @{}) {
  $prices = [ordered]@{}
  foreach ($p in $data.PSObject.Properties) {
    $v = $p.Value
    $g = Get-GePrice $v.$hi $v.$lo $v.$hiW $v.$loW $ref[$p.Name]
    if ($g) { $prices[$p.Name] = [long]$g }
  }
  foreach ($k in $FixedPrices.Keys) { $prices["$k"] = $FixedPrices[$k] }
  return $prices
}

# "Price moves today" (prices can swing a lot within a day). Every Refresh keeps the GE
# prices of right now (prices-live.json; the download is started with the other sites in Invoke-Refresh), and
# once a day the average of the hour before the daily reset (00:00 UTC) as the baseline (prices-reset.json).
# The bank value keeps using the once-a-day prices.json. Returns the live map so prices.json can reuse it.
# The reset hour comes first: it is the reference that picks a side when a live buy/sell pair disagrees.
function Update-BankLivePrices {
  $now = (Get-Date).ToUniversalTime().ToString("o")
  $reset = [DateTimeOffset]::new((Get-Date).ToUniversalTime().Date).ToUnixTimeSeconds()
  $ids = Get-BankPriceIds   # only your items' prices are saved (the downloads hold every item)
  $old = Read-BankFile "prices-reset.json"
  $old = if ($old) { $old | ConvertFrom-Json }
  if (-not $old -or [long]$old.reset -ne $reset) {
    $hour = ConvertTo-PriceMap (Get-Web "$PricesHourUrl$($reset - 3600)" | ConvertFrom-Json).data "avgHighPrice" "avgLowPrice" "highPriceVolume" "lowPriceVolume"
    Save-BankFile "prices-reset.json" ([ordered]@{ t = $now; reset = $reset; prices = (Select-OwnedPrices $hour $ids) } | ConvertTo-Json -Compress)
  } else { $hour = ConvertTo-Hash $old.prices }
  $live = ConvertTo-PriceMap (Get-Web $PricesUrl | ConvertFrom-Json).data "high" "low" "highTime" "lowTime" $hour
  Save-BankFile "prices-live.json" ([ordered]@{ t = $now; prices = (Select-OwnedPrices $live $ids) } | ConvertTo-Json -Compress)
  return $live   # kept in memory for this Refresh only (prices.json picks new bank items from it)
}

# Price moves over the page's other periods. Baseline for a period = the wiki's 24h
# average of the day BEFORE it starts (/24h?timestamp=<day - 86400>, volume weighted when the sides disagree).
# A past day never changes, so each one is downloaded once (prices-past\<date>.json, every GE item) and
# deleted once no period starts on it any more. prices-past.json = the baselines per period, trimmed to the
# items ever saved in the bank + the parts they're valued by, for /api/bank.
$PricesDayUrl = "https://prices.runescape.wiki/api/v1/osrs/24h?timestamp="
$PastDir = Join-Path $BankDir "prices-past"
# Period key -> start date (yyyy-MM-dd), like app.js periodStart: days start at the game's daily reset (00:00 UTC),
# so these are UTC dates; "all" = the first saved bank
function Get-BankPeriodDates {
  $today = (Get-Date).ToUniversalTime().Date
  $d = [ordered]@{ "2d" = $today.AddDays(-1); "3d" = $today.AddDays(-2); "1w" = $today.AddDays(-7); "2w" = $today.AddDays(-14); "month" = $today.AddDays(1 - $today.Day)
    "1m" = $today.AddMonths(-1); "2m" = $today.AddMonths(-2); "3m" = $today.AddMonths(-3); "6m" = $today.AddMonths(-6); "year" = $today.AddDays(1 - $today.DayOfYear)
    "1y" = $today.AddYears(-1); "2y" = $today.AddYears(-2); "3y" = $today.AddYears(-3); "4y" = $today.AddYears(-4); "5y" = $today.AddYears(-5) }
  $histFile = Join-Path $BankDir "history.jsonl"
  if (Test-Path $histFile) {
    $first = [IO.File]::ReadAllLines($histFile, $Utf8) | Where-Object { $_ } | Select-Object -First 1
    if ($first -match '"t":"([^"]+)"') { $d["all"] = [datetime]::Parse($Matches[1]).ToUniversalTime().Date }
  }
  $out = [ordered]@{}
  foreach ($k in $d.Keys) { $out[$k] = $d[$k].ToString("yyyy-MM-dd") }
  return $out
}
function Get-BankPastUrl([string]$date) {
  $ts = [DateTimeOffset]::new([datetime]::SpecifyKind([datetime]::ParseExact($date, "yyyy-MM-dd", $null), "Utc")).ToUnixTimeSeconds()
  return "$PricesDayUrl$($ts - 86400)"
}
# The downloads this Refresh needs (Invoke-Refresh starts them with the other sites)
function Get-BankPastUrls {
  $dates = Get-BankPeriodDates
  @($dates.Values | Sort-Object -Unique | Where-Object { -not (Test-Path (Join-Path $PastDir "$_.json")) } | ForEach-Object { Get-BankPastUrl $_ })
}
function Update-BankPastPrices {
  if (-not (Test-Path $PastDir)) { [void](New-Item -ItemType Directory $PastDir) }
  $dates = Get-BankPeriodDates
  $need = @($dates.Values | Sort-Object -Unique)
  $got = 0
  foreach ($date in $need) {
    $f = Join-Path $PastDir "$date.json"
    if (Test-Path $f) { continue }
    try {
      $day = ConvertTo-PriceMap (Get-Web (Get-BankPastUrl $date) | ConvertFrom-Json).data "avgHighPrice" "avgLowPrice" "highPriceVolume" "lowPriceVolume"
      [IO.File]::WriteAllText($f, ((Select-OwnedPrices $day) | ConvertTo-Json -Compress), $Utf8); $got++   # your items only
    } catch { Write-Host "Prices of $date unavailable: $($_.Exception.Message)" }
  }
  Get-ChildItem $PastDir -Filter *.json | Where-Object { $need -notcontains $_.BaseName } | Remove-Item
  $ids = Get-BankPriceIds
  $tables = @{}
  $out = [ordered]@{}
  foreach ($k in $dates.Keys) {
    $date = $dates[$k]
    if (-not $tables.ContainsKey($date)) {
      $f = Join-Path $PastDir "$date.json"
      if (-not (Test-Path $f)) { continue }
      $all = ConvertTo-Hash ([IO.File]::ReadAllText($f, $Utf8) | ConvertFrom-Json)
      $trim = [ordered]@{}
      foreach ($id in $ids) { if ($all.ContainsKey($id)) { $trim[$id] = $all[$id] } }
      $tables[$date] = $trim
    }
    $out[$k] = [ordered]@{ date = $date; prices = $tables[$date] }
  }
  Save-BankFile "prices-past.json" ($out | ConvertTo-Json -Compress -Depth 4)
  return "past prices: $($out.Count) periods ($got downloaded)"
}
# The only items whose prices are kept:
# every id in any saved bank / gear list, every collection log item you've obtained, every item you've
# had as loot (Loot Tracker), plus the parts
# untradeables are valued by (a Purging staff is valued as a Tormented synapse). The wiki price API sends every
# item in one response (it can't be asked for fewer), so the rest is dropped before anything is saved.
function Get-BankPriceIds {
  $ids = New-Object 'System.Collections.Generic.HashSet[string]'
  $hist = Read-BankFile "history.jsonl"
  if ($hist) { foreach ($m in [regex]::Matches($hist, '\[(\d+),-?\d+\]')) { [void]$ids.Add($m.Groups[1].Value) } }
  foreach ($id in (Get-LoggedIds)) { [void]$ids.Add($id) }
  # Items you've had as drops / loot (the plugin's Loot Tracker totals): Kills & loot values them
  $kcFile = if (Get-Command Get-PluginDir -ErrorAction SilentlyContinue) { Join-Path (Get-PluginDir) "killcounts.json" }
  if ($kcFile -and (Test-Path $kcFile)) {
    foreach ($d in [regex]::Matches([IO.File]::ReadAllText($kcFile, $Utf8), '"drops":\{([^}]*)\}')) {
      foreach ($m in [regex]::Matches($d.Groups[1].Value, '"(\d+)":')) { [void]$ids.Add($m.Groups[1].Value) }
    }
  }
  foreach ($id in (Get-BankGeIds)) { [void]$ids.Add($id) } # offers: the page compares them with the live price
  $mapping = Read-BankFile "mapping.json"; $mapping = if ($mapping) { ConvertTo-Hash ($mapping | ConvertFrom-Json).map } else { @{} }
  $derived = Read-BankFile "derived.json"; $derived = if ($derived) { ConvertTo-Hash ($derived | ConvertFrom-Json) } else { @{} }
  foreach ($id in @($ids)) {
    foreach ($p in @($mapping[$id])) { if ($p) { [void]$ids.Add("$($p[0])") } }
    if ($derived[$id]) { foreach ($o in @($derived[$id].options)) { foreach ($p in @($o)) { [void]$ids.Add("$($p[0])") } } }
  }
  return , $ids
}

# Item ids in the plugin's current Grand Exchange offers (containers.json "ge")
function Get-BankGeIds {
  $file = if (Get-Command Get-PluginDir -ErrorAction SilentlyContinue) { Join-Path (Get-PluginDir) "containers.json" }
  if (-not $file -or -not (Test-Path $file)) { return @() }
  $ge = [regex]::Match([IO.File]::ReadAllText($file, $Utf8), '"ge"\s*:\s*\[([^\]]*)\]')
  @(foreach ($m in [regex]::Matches($ge.Groups[1].Value, '"id"\s*:\s*(\d+)')) { $m.Groups[1].Value })
}

# Value graph at the prices of the time (every daily price update moved the WHOLE graph,
# since every save was valued at today's prices). prices-days.json = {"<UTC date>": {"<id>": gp}}: the once-a-day
# prices.json of each past day, trimmed like prices-past.json and kept when the next day's replaces it. Days from
# before this existed are filled once from the wiki (average of the hour before that day's 00:00 UTC reset, the
# same moment prices.json is taken). The page values a save from a past day with that day's prices; today's
# saves and the current value use prices.json.
function Save-BankDayPrices([string]$date, $prices) {
  $days = Read-BankFile "prices-days.json"
  $days = if ($days) { ConvertTo-Hash ($days | ConvertFrom-Json) } else { @{} }
  if ($days.ContainsKey($date)) { return }
  $trim = [ordered]@{}
  foreach ($id in (Get-BankPriceIds)) { if ($prices.Contains($id)) { $trim[$id] = $prices[$id] } }
  $days[$date] = $trim
  $out = [ordered]@{}
  foreach ($k in ($days.Keys | Sort-Object)) { $out[$k] = $days[$k] }
  Save-BankFile "prices-days.json" ($out | ConvertTo-Json -Compress -Depth 3)
}
function Update-BankDayPrices {
  $hist = Read-BankFile "history.jsonl"
  if (-not $hist) { return "day prices: none needed" }
  $today = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
  $days = Read-BankFile "prices-days.json"
  $have = if ($days) { @((ConvertTo-Hash ($days | ConvertFrom-Json)).Keys) } else { @() }
  $need = @([regex]::Matches($hist, '"t":"(\d{4}-\d\d-\d\d)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique |
    Where-Object { $_ -lt $today -and $have -notcontains $_ })
  foreach ($date in $need) {
    $reset = [DateTimeOffset]::new([datetime]::SpecifyKind([datetime]::ParseExact($date, "yyyy-MM-dd", $null), "Utc")).ToUnixTimeSeconds()
    $hour = ConvertTo-PriceMap (Get-Web "$PricesHourUrl$($reset - 3600)" | ConvertFrom-Json).data "avgHighPrice" "avgLowPrice" "highPriceVolume" "lowPriceVolume"
    Save-BankDayPrices $date $hour
  }
  return "day prices: $($need.Count) filled"
}

# Value graph = snapshots: only today uses today's prices; older points keep their own. Each save
# keeps the GE prices of the moment it was made: one prices-saves.jsonl line per history line, trimmed to the ids of
# that save and the one before it (+ the parts untradeables are valued by). A new save takes the live prices of its
# Refresh ($t / $live); saves without any (from before this existed, or the live download failed) are filled once from
# the wiki's average of the hour they were made in, once that hour is over. The page values today's saves at live
# prices and older ones with these.
function Update-BankSavePrices([string]$t, $live) {
  $histFile = Join-Path $BankDir "history.jsonl"
  if (-not (Test-Path $histFile)) { return "save prices: none needed" }
  $file = Join-Path $BankDir "prices-saves.jsonl"
  $have = New-Object 'System.Collections.Generic.HashSet[string]'
  if (Test-Path $file) {
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($file, $Utf8), '(?m)^\{"t":"([^"]+)"')) { [void]$have.Add($m.Groups[1].Value) }
  }
  $nowS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $hours = @{}; $add = New-Object System.Text.StringBuilder; $prevText = ""; $n = 0
  foreach ($text in [IO.File]::ReadAllLines($histFile, $Utf8)) {
    if (-not $text.Trim()) { continue }
    $lt = [regex]::Match($text, '^\{"t":"([^"]+)"').Groups[1].Value
    if ($lt -and -not $have.Contains($lt)) {
      $prices = $null
      if ($live -and $lt -eq $t) { $prices = $live }
      else {
        $hour = [DateTimeOffset]::Parse($lt).ToUnixTimeSeconds(); $hour -= $hour % 3600
        if ($hour + 3600 -le $nowS) {
          if (-not $hours.ContainsKey($hour)) {
            $hours[$hour] = ConvertTo-PriceMap (Get-Web "$PricesHourUrl$hour" | ConvertFrom-Json).data "avgHighPrice" "avgLowPrice" "highPriceVolume" "lowPriceVolume"
          }
          $prices = $hours[$hour]
        }
      }
      if ($prices) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($m in [regex]::Matches($text + $prevText, '\[(\d+),-?\d+\]')) { [void]$set.Add($m.Groups[1].Value) }
        $want = @($set)
        $trim = [ordered]@{}
        foreach ($id in @($want + (Get-BankParts $want))) { if ($prices.Contains($id)) { $trim[$id] = $prices[$id] } }
        [void]$add.Append((([ordered]@{ t = $lt; prices = $trim }) | ConvertTo-Json -Compress)).Append("`n")
        $n++
      }
    }
    $prevText = $text
  }
  if ($n) { [IO.File]::AppendAllText($file, $add.ToString(), $Utf8) }
  return "save prices: $n stored ($($hours.Count) hours downloaded)"
}

# Wiki image file for an item icon (icons\item\<id>.png), for items that aren't in the collection log
function Get-BankImage([string]$id) {
  $items = Get-JsonHashCached (Join-Path $BankDir "items.json")   # clog.ps1
  if (-not $items) { return $null }
  $it = $items[$id]
  if ($it -and $it[1]) { return $it[1] }
  return $null
}

# GET /api/bank: {"history":[...], "items":{id:[name,image]}, "prices":{"t":..,"prices":{..}}|null,
#                 "mapping":{"<id>":[[part,qty],..]}, "derived":{...}}   (see the top of this file)
function Get-BankJson {
  $histFile = Join-Path $BankDir "history.jsonl"
  $lines = [string[]]@(if (Test-Path $histFile) { [IO.File]::ReadAllText($histFile, $Utf8).Split([char[]]"`r`n", [StringSplitOptions]::RemoveEmptyEntries) })
  $items = Read-BankFile "items.json"; if (-not $items) { $items = "{}" }
  $prices = Read-BankFile "prices.json"; if (-not $prices) { $prices = "null" }
  $mapping = Read-BankFile "mapping.json"; $mapping = if ($mapping) { ($mapping -replace '^\{"t":"[^"]*","map":', '') -replace '\}$', '' } else { "{}" }
  $derived = Read-BankFile "derived.json"; if (-not $derived) { $derived = "{}" }
  $slots = Read-BankFile "slots.json"; if (-not $slots) { $slots = "{}" }
  $gear = Read-BankFile "gear.json"; if (-not $gear) { $gear = "null" }
  $live = Read-BankFile "prices-live.json"; if (-not $live) { $live = "null" }
  $reset = Read-BankFile "prices-reset.json"; if (-not $reset) { $reset = "null" }
  $past = Read-BankFile "prices-past.json"; if (-not $past) { $past = "null" }
  $days = Read-BankFile "prices-days.json"; if (-not $days) { $days = "{}" }
  $saves = Read-BankFile "prices-saves.jsonl"
  $saves = if ($saves) { [string]::Join(",", $saves.Split([char[]]"`r`n", [StringSplitOptions]::RemoveEmptyEntries)) } else { "" }
  return "{""history"":[" + [string]::Join(",", $lines) + "],""items"":" + $items + ",""prices"":" + $prices +
    ",""mapping"":" + $mapping + ",""derived"":" + $derived + ",""slots"":" + $slots + ",""gear"":" + $gear + ",""live"":" + $live + ",""reset"":" + $reset + ",""past"":" + $past + ",""days"":" + $days + ",""saves"":[" + $saves + "]}"
}
