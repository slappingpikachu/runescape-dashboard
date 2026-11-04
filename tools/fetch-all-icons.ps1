# Saves EVERY item icon, every monster picture and every pickpocketable NPC's picture from the OSRS Wiki into .\icons
# (talk-only NPCs are skipped: the dashboard never shows them), so the dashboard never has
# to ask the wiki for a picture while you use it.
# Run once (takes a while; safe to stop and run again, it skips what is already saved). Rerun after a big game
# update to pick up new items/monsters. Only contacts oldschool.runescape.wiki.
#   powershell -ExecutionPolicy Bypass -File tools\fetch-all-icons.ps1 [-Workers 6]
# icons\item\<item id>.png        item icon (outlined white), one file per item id
# icons\npc\<name-slug>.png        monster/NPC picture, max 64 px, outlined white
# data\plugin\npc-images.json      name -> wiki file (so a Refresh doesn't look names up again)
param([int]$Workers = 6)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Root = Split-Path $PSScriptRoot -Parent
$UA = "osrs-progress-dashboard/1.0 (self-hosted OSRS progress dashboard)"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Api = "https://oldschool.runescape.wiki/api.php"
$ItemDir = Join-Path $Root "icons\item"; $NpcDir = Join-Path $Root "icons\npc"
foreach ($d in $ItemDir, $NpcDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }

function Get-Bucket([string]$bucket, [string]$fields) {
  $rows = New-Object System.Collections.ArrayList
  for ($off = 0; ; $off += 5000) {
    $q = "bucket('$bucket').select($fields).limit(5000).offset($off).run()"
    $res = Invoke-RestMethod -UserAgent $UA -TimeoutSec 120 -Uri "${Api}?action=bucket&format=json&query=$([uri]::EscapeDataString($q))"
    $page = @($res.bucket)
    foreach ($r in $page) { [void]$rows.Add($r) }
    if ($page.Count -lt 5000) { break }
    Start-Sleep -Milliseconds 500
  }
  return $rows
}
$fileOf = { param($img) (@($img)[0] -replace '^File:', '').Trim() }

# ---- Jobs: one per wiki file; each lists where it is saved
$jobs = @{}   # wiki file -> @{ kind; outs = list of paths }
Write-Host "Reading the wiki's item list..."
foreach ($r in (Get-Bucket "infobox_item" "'item_id','image'")) {
  $file = & $fileOf $r.image
  if (-not $file) { continue }
  foreach ($id in @($r.item_id)) {
    if ("$id" -notmatch '^\d+$') { continue }
    $out = Join-Path $ItemDir "$id.png"
    if (Test-Path $out) { continue }
    if (-not $jobs["item|$file"]) { $jobs["item|$file"] = @{ kind = "item"; file = $file; outs = New-Object System.Collections.ArrayList } }
    [void]$jobs["item|$file"].outs.Add($out)
  }
}
Write-Host "Reading the wiki's monster and NPC lists..."
$mapFile = Join-Path $Root "data\plugin\npc-images.json"
$map = @{}
if (Test-Path $mapFile) { foreach ($p in ([IO.File]::ReadAllText($mapFile, $Utf8) | ConvertFrom-Json).PSObject.Properties) { $map[$p.Name] = [string]$p.Value } }
$best = @{}   # name -> file (the plain "<name>.png" picture wins, like plugin.ps1 Update-NpcIcons)
# Only NPCs the dashboard can show: every monster (can be killed) + NPCs you can pickpocket
# (the "Thievable NPCs" table on the wiki's Thieving page). Talk-only NPCs are skipped.
$thieving = (Invoke-WebRequest -UseBasicParsing -UserAgent $UA -TimeoutSec 60 -Uri "https://oldschool.runescape.wiki/w/Thieving?action=raw").Content
$table = ($thieving -split '===\s*Thievable NPCs\s*===')[1]
$table = $table.Substring(0, $table.IndexOf("`n|}"))
$pick = @{}
foreach ($m in [regex]::Matches($table, '\[\[([^\]|#]+)|\{\{(?:plinkt|plink|chatlp)\|([^|}]+)|txt=([^|}]+)')) {
  $v = ($m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value).Trim()
  if ($v) { $pick[$v] = 1; $pick[($v -replace '\s*\([^)]*\)$', '')] = 1 }
}
Write-Host "$($pick.Count) pickpocket names from the wiki's Thieving page"
$rows = @(Get-Bucket "infobox_monster" "'name','image'" | ForEach-Object { @{ n = [string]$_.name; img = $_.image } }) +
        @(Get-Bucket "infobox_npc" "'page_name','image'" | Where-Object { $pick[[string]$_.page_name] -or $pick[([string]$_.page_name -replace '\s*\([^)]*\)$', '')] } |
          ForEach-Object { @{ n = ([string]$_.page_name -replace '\s*\([^)]*\)$', ''); img = $_.image } })
foreach ($r in $rows) {
  $n = $r.n; $file = & $fileOf $r.img
  if (-not $n -or -not $file) { continue }
  if ($file -eq "$n.png" -or -not $best[$n]) { $best[$n] = $file }
}
$slugSeen = @{}
foreach ($n in $best.Keys) {
  if (-not $map[$n]) { $map[$n] = $best[$n] }
  $slug = ($n.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if (-not $slug -or $slugSeen[$slug]) { continue }
  $slugSeen[$slug] = 1
  $out = Join-Path $NpcDir "$slug.png"
  if (Test-Path $out) { continue }
  $file = $map[$n]
  if (-not $jobs["npc|$file"]) { $jobs["npc|$file"] = @{ kind = "npc"; file = $file; outs = New-Object System.Collections.ArrayList } }
  [void]$jobs["npc|$file"].outs.Add($out)
}
[IO.File]::WriteAllText($mapFile, ($map | ConvertTo-Json -Compress), $Utf8)
$list = @($jobs.Values)
Write-Host "$($list.Count) pictures to download ($(@($list | Where-Object { $_.kind -eq 'item' }).Count) item, $(@($list | Where-Object { $_.kind -eq 'npc' }).Count) monster/NPC)"
if (-not $list.Count) { Write-Host "Everything is already saved."; return }

# ---- Download in a few parallel workers (Special:Redirect/file follows renamed files; NPCs as 64 px thumbnails)
$worker = {
  param($job, $outlineScript, $UA)
  . $outlineScript
  Add-Type -AssemblyName System.Drawing
  $ProgressPreference = "SilentlyContinue"
  $name = [uri]::EscapeDataString(($job.file -replace ' ', '_'))
  $url = "https://oldschool.runescape.wiki/w/Special:Redirect/file/$name" + $(if ($job.kind -eq "npc") { "?width=64" } else { "" })
  for ($try = 0; $try -lt 3; $try++) {
    try { $bytes = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -UserAgent $UA -MaximumRedirection 5).Content; break }
    catch { if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return "MISSING $($job.file)" }; Start-Sleep -Seconds (2 * ($try + 1)) }
  }
  if (-not $bytes) { return "FAILED $($job.file)" }
  try {
    if ($job.kind -eq "npc") {
      $src = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $bytes)))
      $scale = [Math]::Min(1.0, 64.0 / [Math]::Max($src.Width, $src.Height))
      $w = [Math]::Max(1, [int]($src.Width * $scale)); $h = [Math]::Max(1, [int]($src.Height * $scale))
      $bmp = New-Object Drawing.Bitmap $w, $h
      $g = [Drawing.Graphics]::FromImage($bmp)
      $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.DrawImage($src, 0, 0, $w, $h); $g.Dispose(); $src.Dispose()
      $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
      $bytes = $ms.ToArray()
    }
    $bytes = Add-IconOutline $bytes
  } catch { return "BAD IMAGE $($job.file)" }
  foreach ($o in $job.outs) { [IO.File]::WriteAllBytes($o, $bytes) }
  return $null
}
$pool = [RunspaceFactory]::CreateRunspacePool(1, $Workers); $pool.Open()
$outline = Join-Path $Root "icon-outline.ps1"
$running = New-Object System.Collections.ArrayList
$done = 0; $problems = New-Object System.Collections.ArrayList
$queue = New-Object System.Collections.Queue (, $list)
$started = Get-Date
while ($queue.Count -or $running.Count) {
  while ($queue.Count -and $running.Count -lt $Workers * 2) {
    $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($worker).AddArgument($queue.Dequeue()).AddArgument($outline).AddArgument($UA)
    [void]$running.Add(@{ ps = $ps; h = $ps.BeginInvoke() })
  }
  foreach ($r in @($running)) {
    if (-not $r.h.IsCompleted) { continue }
    $msg = $r.ps.EndInvoke($r.h) | Select-Object -Last 1
    if ($msg) { [void]$problems.Add($msg) }
    $r.ps.Dispose(); $running.Remove($r); $done++
    if ($done % 500 -eq 0) { Write-Host ("{0} / {1} ({2:n0} s)" -f $done, $list.Count, ((Get-Date) - $started).TotalSeconds) }
  }
  Start-Sleep -Milliseconds 20
}
$pool.Close()
Write-Host "Done: $($list.Count - $problems.Count) saved, $($problems.Count) not available."
if ($problems.Count) {
  $log = Join-Path $Root "icons\not-on-wiki.txt"
  [IO.File]::WriteAllLines($log, [string[]]($problems | Sort-Object -Unique), $Utf8)
  Write-Host "List: $log"
}
