# Builds data\bank\mapping.json: what untradeable items are worth, from RuneLite's own list
# (ItemMapping.java, the same one RuneLite's bank value uses). Example: Bow of faerdhinen (any colour)
# -> 1 x Bow of faerdhinen (inactive); Purging staff -> 1 x Tormented synapse; Scythe of vitur ->
# Scythe of vitur (uncharged). Run ONCE; rerun only when Jagex adds items (RuneLite updates the list).
#   powershell -File tools\fetch-item-mapping.ps1
# data\bank\mapping.json  {"t":ISO,"map":{"<untradeable id>":[[tradeable id, quantity], ...]}}
$ErrorActionPreference = "Stop"
$Project = Split-Path $PSScriptRoot -Parent
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$ProgressPreference = "SilentlyContinue"
$Raw = "https://raw.githubusercontent.com/runelite/runelite/master"
$get = { param($path) (Invoke-WebRequest -Uri "$Raw/$path" -UseBasicParsing -TimeoutSec 60 -UserAgent "osrs-progress-dashboard/1.0 (self-hosted OSRS progress dashboard)").Content }

# Item names used in the Java files -> ids (top-level constants only; nested Cert/Placeholder classes are indented deeper)
$ids = @{}
foreach ($m in [regex]::Matches((& $get "runelite-api/src/main/java/net/runelite/api/gameval/ItemID.java"), '(?m)^\tpublic static final int (\w+) = (\d+);')) {
  $ids[$m.Groups[1].Value] = [int]$m.Groups[2].Value
}

# Variation groups (item_variations.json): ids of the same item in other colours/states; the first id is the base
$variations = @{}
foreach ($g in (& $get "runelite-client/src/main/resources/item_variations.json" | ConvertFrom-Json).PSObject.Properties) {
  $group = @($g.Value)
  foreach ($id in $group) { $variations[[int]$id] = $group }
}

# ITEM_X(ItemID.TRADEABLE[, includeVariations][, quantityL], ItemID.UNTRADEABLE, ...)
$src = & $get "runelite-client/src/main/java/net/runelite/client/game/ItemMapping.java"
$map = @{}
$entries = 0
foreach ($m in [regex]::Matches($src, '(?s)\bITEM_\w+\s*\(([^)]*)\)')) {
  $args_ = @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($args_[0] -notmatch '^ItemID\.(\w+)$' -or -not $ids.ContainsKey($Matches[1])) { continue }
  $tradeable = $ids[$Matches[1]]
  $withVariations = $false; $qty = 1L; $rest = @()
  foreach ($a in $args_[1..($args_.Count - 1)]) {
    if ($a -eq "true" -or $a -eq "false") { $withVariations = $a -eq "true" }
    elseif ($a -match '^([\d_]+)L?$') { $qty = [long]($Matches[1] -replace '_', '') }
    elseif ($a -match '^ItemID\.(\w+)$' -and $ids.ContainsKey($Matches[1])) { $rest += $ids[$Matches[1]] }
  }
  if (-not $rest.Count) { continue }
  $entries++
  foreach ($u in $rest) {
    $targets = if ($withVariations -and $variations.ContainsKey($u)) { $variations[$u] } else { @($u) }
    foreach ($t in $targets) {
      if ($t -eq $tradeable) { continue }
      if (-not $map.ContainsKey("$t")) { $map["$t"] = New-Object System.Collections.ArrayList }
      [void]$map["$t"].Add(@($tradeable, $qty))
    }
  }
}

$dir = Join-Path $Project "data\bank"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
$json = [ordered]@{ t = (Get-Date).ToUniversalTime().ToString("o"); map = $map } | ConvertTo-Json -Compress -Depth 5
[IO.File]::WriteAllText((Join-Path $dir "mapping.json"), $json, $Utf8)
"$entries RuneLite mappings -> $($map.Count) untradeable item ids -> data\bank\mapping.json ($([int]($json.Length / 1KB)) KB)"
