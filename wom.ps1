# Optional one-time import of older progress from Wise Old Man (wiseoldman.net) into data\history.jsonl.
# Used by the dashboard's "Import from Wise Old Man" banner (server.ps1 POST /api/wom) and by tools\import-wom.ps1.
# Only snapshots OLDER than the first local snapshot are imported, converted to the official hiscores format and
# de-duplicated (kept only when something changed). A backup of history.jsonl is written first.
# Wise Old Man is only contacted when the player chooses to import: 50 snapshots per request, 3.5 s apart.
# Dot-sourced; needs nothing else.

$WomUA = "osrs-progress-dashboard/1.0 (self-hosted OSRS progress dashboard)"

# True once Wise Old Man history is in the file (then the dashboard never offers the import again)
function Test-WomImported([string]$HistoryFile) {
  return (Test-Path $HistoryFile) -and ([IO.File]::ReadAllText($HistoryFile).Contains('"src":"wom"'))
}

# Returns @{ found; kept; from; to; unmatched; backup }. Throws a readable message when it can't import.
function Import-WomHistory([string]$Player, [string]$HistoryFile, [switch]$DryRun) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  if (-not $Player) { throw "No player name." }
  if (-not (Test-Path $HistoryFile)) { throw "No history yet - press Update once first." }
  $local = @([IO.File]::ReadAllLines($HistoryFile, $utf8) | Where-Object { $_.Trim() })
  if (-not $local.Count) { throw "No history yet - press Update once first." }
  if ($local | Where-Object { $_ -like '*"src":"wom"*' }) { throw "Wise Old Man history was already imported." }
  $template = ($local | Select-Object -Last 1) | ConvertFrom-Json
  $firstLocal = ($local | ForEach-Object { [datetime]::Parse(($_ | ConvertFrom-Json).t).ToUniversalTime() } | Sort-Object | Select-Object -First 1)
  $endDate = $firstLocal.AddSeconds(-1).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

  # ---- every Wise Old Man snapshot before the first local one (50 per page, rate-limit friendly)
  $snaps = @(); $offset = 0
  do {
    $url = "https://api.wiseoldman.net/v2/players/$([uri]::EscapeDataString($Player))/snapshots?startDate=2000-01-01T00:00:00.000Z&endDate=$endDate&limit=50&offset=$offset"
    try { $page = @((Invoke-RestMethod -Uri $url -TimeoutSec 30 -UserAgent $WomUA) | ForEach-Object { $_ }) }   # unroll PS 5.1 array
    catch {
      $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
      if ($code -eq 404) { throw "Wise Old Man doesn't track '$Player'. Nothing to import." }
      if ($code -eq 429) { throw "Wise Old Man is busy (too many requests). Try again in a few minutes." }
      throw "Could not reach Wise Old Man. Try again later."
    }
    $snaps += $page; $offset += 50
    Write-Host "Wise Old Man: fetched $($snaps.Count) snapshots..."
    if ($page.Count -eq 50) { Start-Sleep -Milliseconds 3500 }
  } while ($page.Count -eq 50)
  if (-not $snaps.Count) { throw "Wise Old Man has no snapshots of '$Player' from before your first Update. Nothing to import." }
  $snaps = $snaps | Sort-Object { [datetime]::Parse($_.createdAt) }

  # ---- map official names -> Wise Old Man keys
  $norm = { param($s) ($s.ToLower() -replace '[^a-z0-9]', '') }
  $aliases = @{ "runecraft" = "runecrafting"; "tombsofamascutexpertmode" = "tombsofamascutexpert" }
  $womKeys = @{}
  foreach ($grp in "skills", "bosses", "activities") {
    foreach ($p in $snaps[-1].data.$grp.PSObject.Properties) { $womKeys[(& $norm $p.Name)] = @($grp, $p.Name) }
  }
  $findKey = {
    param($name)
    $k = & $norm $name
    if ($aliases.ContainsKey($k)) { $k = $aliases[$k] }
    $womKeys[$k]
  }
  $unmatched = @()
  foreach ($s in $template.d.skills) { if (-not (& $findKey $s.name)) { $unmatched += $s.name } }
  $bossStart = [array]::IndexOf(@($template.d.activities.name), "Collections Logged") + 1
  for ($i = 0; $i -lt $template.d.activities.Count; $i++) {
    $a = $template.d.activities[$i]
    if (($i -ge $bossStart -or $a.name -like "Clue Scrolls*") -and -not (& $findKey $a.name)) { $unmatched += $a.name }
  }

  # ---- convert + de-duplicate
  $lines = New-Object System.Collections.ArrayList
  $lastSig = $null
  foreach ($w in $snaps) {
    foreach ($s in $template.d.skills) {
      $k = & $findKey $s.name
      $v = if ($k) { $w.data.($k[0]).($k[1]) } else { $null }
      if ($v) { $s.xp = [long]$v.experience; $s.level = [int]$v.level; $s.rank = [int]$v.rank } else { $s.xp = -1; $s.level = 1; $s.rank = -1 }
    }
    foreach ($a in $template.d.activities) {
      $k = & $findKey $a.name
      $v = if ($k) { $w.data.($k[0]).($k[1]) } else { $null }
      if ($v) { $a.score = if ($k[0] -eq "bosses") { [int]$v.kills } else { [int]$v.score }; $a.rank = [int]$v.rank } else { $a.score = -1; $a.rank = -1 }
    }
    $sig = (@($template.d.skills.xp) + @($template.d.activities.score)) -join ","
    if ($sig -eq $lastSig) { continue }
    $lastSig = $sig
    $t = [datetime]::Parse($w.createdAt).ToUniversalTime().ToString("o")
    [void]$lines.Add("{""t"":""$t"",""src"":""wom"",""d"":$($template.d | ConvertTo-Json -Depth 5 -Compress)}")
  }

  $result = @{ found = $snaps.Count; kept = $lines.Count; from = $snaps[0].createdAt; to = $snaps[-1].createdAt; unmatched = $unmatched; backup = $null }
  if ($DryRun) { return $result }
  $dir = Split-Path $HistoryFile -Parent
  $result.backup = Join-Path $dir ("history.backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".jsonl")
  Copy-Item $HistoryFile $result.backup
  [IO.File]::WriteAllLines($HistoryFile, [string[]](@($lines) + @($local)), $utf8)
  return $result
}
