# Helpers for the wiki tools in this folder (fetch-clog-layout.ps1): downloads from the OSRS Wiki, and item names by
# id the way the dashboard keeps them (data\bank\items.json). Dot-sourced; needs $DataDir and $Utf8.
$ClogDir = Join-Path $DataDir "clog"
$BankDir = Join-Path $DataDir "bank"
$WikiApi = "https://oldschool.runescape.wiki/api.php"
$WikiUA  = "osrs-progress-dashboard/1.0 (self-hosted OSRS progress dashboard)"

function Get-Web([string]$url) {
  $ProgressPreference = "SilentlyContinue"   # PS 5.1's progress bar makes downloads much slower
  (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -UserAgent $WikiUA).Content
}

function ConvertTo-Hash($obj) {
  $h = @{}
  if ($obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
  return $h
}

function Save-ClogFile([string]$name, [string]$text) {
  [IO.File]::WriteAllText((Join-Path $ClogDir $name), $text, $Utf8)
}

function Read-BankFile([string]$name) {
  $f = Join-Path $BankDir $name
  if (Test-Path $f) { return [IO.File]::ReadAllText($f, $Utf8) }
  return $null
}

function Save-BankFile([string]$name, [string]$text) {
  [IO.File]::WriteAllText((Join-Path $BankDir $name), $text, $Utf8)
}

function Read-BankHash([string]$name, [string]$prop) {
  $text = Read-BankFile $name
  if (-not $text) { return @{} }
  $obj = $text | ConvertFrom-Json
  if ($prop) { $obj = $obj.$prop }
  return ConvertTo-Hash $obj
}

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
