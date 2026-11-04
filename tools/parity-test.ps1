# Parity test: the desktop app (app\src-tauri) against the PowerShell version (server.ps1 + scripts), on COPIES.
# Usage: powershell -ExecutionPolicy Bypass -File tools\parity-test.ps1 [-Fresh] [-Wom] [-Keep]
#   (build the app first: cd app\src-tauri; cargo build)
# The real data, settings and plugin folder are only read. Each scenario gets two identical copies of the dashboard;
# the app works on one, the scripts on the other, both at the same fixed "now". The app downloads for real and
# records every answer; the scripts then get exactly those answers (no network), so any difference is in the code.
# Then every file under data\ (and settings.json, new icons) is compared:
#   same bytes  - identical files
#   same data   - same JSON data with keys in another order (the scripts write unordered hashtables) or 1 vs 1.0
#   DIFFERENT   - a real difference (fails the test)
# Scenarios: GET answers on the real data; Refresh on the real data, twice (the 2nd = "no change" paths);
# -Fresh: first start on an empty install (setup with your player name: every name/price/slot lookup);
# -Wom: (with -Fresh) the Wise Old Man import after that setup.
param([string]$Project = (Split-Path $PSScriptRoot -Parent),
  [string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) "app\src-tauri\target\debug\osrs-dashboard.exe"),
  [string]$Work = (Join-Path $env:TEMP "osrs-parity"), [switch]$Fresh, [switch]$Wom, [switch]$Keep)
$ErrorActionPreference = "Stop"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path $Exe)) { throw "Build the app first (cd app\src-tauri; cargo build): $Exe" }
if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
New-Item -ItemType Directory $Work | Out-Null
$Player = ([IO.File]::ReadAllText((Join-Path $Project "settings.json")) | ConvertFrom-Json).player
$Slug = (($Player -replace [char]160, ' ').Trim().ToLowerInvariant() -replace '[^a-z0-9_-]+', '_')
$RealPlugin = Join-Path $HOME ".runelite\plugin-data\osrsdatasync\$Slug"
# One fixed "now" for both (the current time, so the wiki's price history has the hours asked for)
$Now = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$scenario, [string]$what, [string]$result, [string]$note = "") {
  $results.Add([pscustomobject]@{ scenario = $scenario; what = $what; result = $result; note = $note })
}

# ---- a copy of the dashboard: pages, scripts, icons, data (all, or only the reference lists a new install has)
function New-Copy([string]$dir, [switch]$Empty) {
  New-Item -ItemType Directory $dir, "$dir\data", "$dir\plugin-root\$Slug" | Out-Null
  foreach ($f in "index.html", "app.js", "styles.css") { Copy-Item "$Project\$f" $dir }
  Copy-Item "$Project\*.ps1" $dir
  foreach ($d in "vendor", "icons") { robocopy "$Project\$d" "$dir\$d" /E /NFL /NDL /NJH /NJS /NP /MT:16 | Out-Null }
  if (Test-Path $RealPlugin) { Copy-Item "$RealPlugin\*" "$dir\plugin-root\$Slug" }
  if ($Empty) {
    foreach ($d in "clog", "progress", "bank") { New-Item -ItemType Directory "$dir\data\$d" | Out-Null }
    foreach ($f in "clog\categories.json", "clog\items.json", "clog\images.json", "progress\diary-tasks.json",
      "progress\ca-tasks.json", "progress\miniquests.json", "progress\quest-reqs.json", "bank\mapping.json") {
      if (Test-Path "$Project\data\$f") { Copy-Item "$Project\data\$f" "$dir\data\$f" }
    }
  } else {
    robocopy "$Project\data" "$dir\data" /E /NFL /NDL /NJH /NJS /NP /MT:16 | Out-Null
    Copy-Item "$Project\settings.json" $dir
  }
}

# ---- the PowerShell side: the scripts as they are, minus server.ps1's web server, plus stubs that answer every
# download from the app's recording. Every empty @{} becomes an insertion-ordered table (OHash), so the scripts look
# things up in the same order as the app (a plain hashtable's order is arbitrary).
$Harness = @'
param([string]$Mode, [string]$Tape, [string]$Now, [string]$PluginRoot, [string]$Out, [string]$Body)
$ErrorActionPreference = "Continue"
Add-Type -TypeDefinition @"
public class OHash : System.Collections.Specialized.OrderedDictionary {
  public OHash() : base(System.StringComparer.OrdinalIgnoreCase) { }
  public bool ContainsKey(object k) { return Contains(k); }
  // A number is a key here (a hashtable has no positions)
  public new object this[int key] { get { return base[(object)key]; } set { base[(object)key] = value; } }
}
public class StubResponse { public int StatusCode; public StubResponse(int c) { StatusCode = c; } }
public class StubWebException : System.Exception {
  public StubResponse Response;
  public StubWebException(int c) : base("The remote server returned an error: (" + c + ").") { Response = new StubResponse(c); }
}
"@
$TestPluginRoot = $PluginRoot; $TestOut = $Out
. (Join-Path $PSScriptRoot "server.ps1")
$PluginRoot = $TestPluginRoot; $Out = $TestOut   # plugin.ps1 set the real folder
$Fixed = [DateTime]::Parse($Now, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
function Get-Date { param([string]$Format) $d = $Fixed.ToLocalTime(); if ($Format) { $d.ToString($Format) } else { $d } }
function Start-Sleep { }
$TapeIndex = @{}
foreach ($l in [IO.File]::ReadAllLines((Join-Path $Tape "index.tsv"), $Utf8)) { $p = $l.Split("`t"); if ($p.Count -eq 3) { $TapeIndex[$p[0]] = $p } }
function Get-TapeKey([string]$url) {
  $u = [uri]::UnescapeDataString($url)
  [regex]::Replace($u, 'bucket\.Or\((.*)\)\)\.limit', {
    param($m) $t = [string[]]@([regex]::Matches($m.Groups[1].Value, "\{'[^']*','(?:[^'\\]|\\.)*'\}") | ForEach-Object { $_.Value })
    [Array]::Sort($t, [StringComparer]::Ordinal); "bucket.Or(" + ($t -join ",") + ")).limit" })
}
function Get-Taped([string]$url) {
  $e = $TapeIndex[(Get-TapeKey $url)]
  if (-not $e) { [IO.File]::AppendAllText((Join-Path $Out "ps-not-recorded.txt"), "$url`n"); return @(0, $null) }
  $code = [int]$e[2]
  if ($code -ge 200 -and $code -lt 300) { return @($code, [IO.File]::ReadAllBytes((Join-Path $Tape $e[1]))) }
  return @($code, $null)
}
function Start-Get([string]$url, [string]$ua) { $url }
function Get-Done($task) { $r = Get-Taped $task; if ($null -ne $r[1]) { @($r[0], $Utf8.GetString($r[1])) } else { @($r[0], $null) } }
function Get-Web([string]$url) {
  if ($script:Prefetch -and $script:Prefetch.Contains($url)) { return $script:Prefetch[$url] }
  $r = Get-Taped $url
  if ($r[0] -lt 200 -or $r[0] -ge 300) { throw (New-Object StubWebException ([int]$r[0])) }
  $body = $Utf8.GetString($r[1])
  if ($script:Prefetch -is [System.Collections.IDictionary]) { $script:Prefetch[$url] = $body }
  $body
}
function Invoke-WebRequest { param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $UserAgent)
  $r = Get-Taped $Uri; if ($r[0] -lt 200 -or $r[0] -ge 300) { throw (New-Object StubWebException ([int]$r[0])) }
  [pscustomobject]@{ Content = [byte[]]$r[1] } }
function Invoke-RestMethod { param($Uri, $TimeoutSec, $UserAgent)
  $r = Get-Taped $Uri; if ($r[0] -lt 200 -or $r[0] -ge 300) { throw (New-Object StubWebException ([int]$r[0])) }
  $Utf8.GetString($r[1]) | ConvertFrom-Json }
function Save-Answer([string]$name, [string]$text) { [IO.File]::WriteAllText((Join-Path $Out $name), $text, $Utf8) }

switch ($Mode) {
  "get" {
    Save-Answer "history.json" (Get-History); Save-Answer "clog.json" (Get-ClogJson); Save-Answer "bank.json" (Get-BankJson)
    Save-Answer "miniquests.json" (Get-MiniquestsJson); Save-Answer "diary-tasks.json" (Get-DiaryTasksJson); Save-Answer "quest-reqs.json" (Get-QuestReqsJson)
    Save-Answer "ca-tasks.json" (Get-CaTasksJson); Save-Answer "ca-history.json" (Get-CaHistoryJson)
    Save-Answer "progress.json" (Get-ProgressJson); Save-Answer "plugin.json" (Get-PluginJson)
    $offer = [bool]$Player -and -not $WomAsked -and -not (Test-WomImported $HistoryFile)
    Save-Answer "settings.json" ([ordered]@{ player = $(if ($Player) { $Player } else { $null }); womOffer = $offer } | ConvertTo-Json -Compress)
    # Pictures deleted from the copy: downloaded + outlined again (server.ps1's /icons routes)
    foreach ($icon in @($Body -split ',' | Where-Object { $_ })) {
      $kind, $name = $icon -split '/', 2
      if ($kind -eq "item") { [void](Get-ItemIcon $name) } else { [void](Get-Icon $kind $name) }
    }
  }
  "refresh" { $r = Invoke-Refresh; Save-Answer "status.txt" "$($r[0]) $($r[1])" }
  "setup" {   # server.ps1's /api/setup route
    $name = try { ([string]($Body | ConvertFrom-Json).player).Trim() } catch { "" }
    $script:Player = $name; $r = Invoke-Refresh
    if ($r[0] -eq 200) { $script:WomAsked = $false; Save-Settings } else { $script:Player = "" }
    Save-Answer "status.txt" "$($r[0]) $($r[1])"
  }
  "wom" {     # server.ps1's /api/wom route, {"import": true}
    try {
      $r = Import-WomHistory $Player $HistoryFile; $script:WomAsked = $true; Save-Settings
      $msg = "Imported $($r.kept) snapshots from Wise Old Man ($(([datetime]$r.from).ToString('MMM d, yyyy')) to $(([datetime]$r.to).ToString('MMM d, yyyy')))."
      Save-Answer "status.txt" "200 {""message"":$(ConvertTo-JsonString $msg)}"
    } catch {
      $msg = $_.Exception.Message
      if ($msg -match "doesn't track|no snapshots|already imported") { $script:WomAsked = $true; Save-Settings }
      Save-Answer "status.txt" "422 {""error"":$(ConvertTo-JsonString $msg)}"
    }
  }
}
'@

function Prepare-Ps([string]$dir) {
  foreach ($f in Get-ChildItem $dir -Filter *.ps1) {
    $t = [IO.File]::ReadAllText($f.FullName)
    if ($f.Name -eq "server.ps1") { $t = $t.Substring(0, $t.IndexOf("# Listen on the whole home network")) }
    $t = [regex]::Replace($t, '(?<!\])@\{\}', '(New-Object OHash)')
    [IO.File]::WriteAllText($f.FullName, $t, (New-Object System.Text.UTF8Encoding($true)))
  }
  [IO.File]::WriteAllText("$dir\parity-run.ps1", $Harness, (New-Object System.Text.UTF8Encoding($true)))
}
function Invoke-Ps([string]$dir, [string]$mode, [string]$tape, [string]$out, [string]$body = "") {
  New-Item -ItemType Directory $out -Force | Out-Null
  $ErrorActionPreference = "Continue"   # the scripts' console messages arrive as stderr
  $a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$dir\parity-run.ps1", "-Mode", $mode, "-Tape", $tape, "-Now", $Now,
    "-PluginRoot", "$dir\plugin-root", "-Out", $out)
  if ($body) { $a += @("-Body", ($body -replace '"', '\"')) }
  $log = & powershell @a 2>&1
  [IO.File]::WriteAllLines("$out\ps.log", [string[]]@($log | ForEach-Object { "$_" }), $Utf8)
}
# ---- the app side
function Invoke-App([string]$dir, [string]$method, [string]$path, [string]$outFile, [string]$tape, [string]$body = "") {
  $env:OSRS_DASH_NOW = $Now; $env:OSRS_PLUGIN_ROOT = "$dir\plugin-root"; $env:OSRS_DASH_NET_RECORD = $tape
  $a = @("--root", $dir, "--cli", $method, $path); if ($body) { $a += $body }; $a += @("--out", $outFile)
  $p = Start-Process $Exe -ArgumentList ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) `
    -NoNewWindow -Wait -PassThru -RedirectStandardError "$outFile.log"
  Remove-Item Env:\OSRS_DASH_NET_RECORD, Env:\OSRS_PLUGIN_ROOT, Env:\OSRS_DASH_NOW
  return $p.ExitCode
}

# ---- comparing
function Compare-File([string]$scenario, [string]$name, [string]$a, [string]$b) {
  $ina = Test-Path $a; $inb = Test-Path $b
  if (-not $ina -and -not $inb) { Add-Result $scenario $name "same" "neither wrote it"; return }
  if (-not $ina -or -not $inb) { Add-Result $scenario $name "DIFFERENT" $(if ($ina) { "only written by the scripts" } else { "only written by the app" }); return }
  $ba = [IO.File]::ReadAllBytes($a); $bb = [IO.File]::ReadAllBytes($b)
  if ($ba.Length -eq $bb.Length -and [Linq.Enumerable]::SequenceEqual($ba, $bb)) { Add-Result $scenario $name "same bytes"; return }
  if ($a -match '\.png$') { Compare-Png $scenario $name $a $b; return }
  $why = (& $Exe --same $a $b) -join " "
  if ($LASTEXITCODE -eq 0) { Add-Result $scenario $name "same data" "key order / number format" }
  else { Add-Result $scenario $name "DIFFERENT" $why }
}
Add-Type -AssemblyName System.Drawing
function Compare-Png([string]$scenario, [string]$name, [string]$a, [string]$b) {
  $x = [Drawing.Bitmap]::new($a); $y = [Drawing.Bitmap]::new($b)
  try {
    if ($x.Width -ne $y.Width -or $x.Height -ne $y.Height) { Add-Result $scenario $name "DIFFERENT" "$($x.Width)x$($x.Height) vs $($y.Width)x$($y.Height)"; return }
    # Colours weighed by their opacity (a fully transparent pixel's colour is invisible)
    $max = 0; $sum = 0.0
    for ($i = 0; $i -lt $x.Width; $i++) { for ($j = 0; $j -lt $x.Height; $j++) {
      $p = $x.GetPixel($i, $j); $q = $y.GetPixel($i, $j)
      foreach ($d in ([math]::Abs($p.A - $q.A)), ([math]::Abs($p.R * $p.A - $q.R * $q.A) / 255), ([math]::Abs($p.G * $p.A - $q.G * $q.A) / 255), ([math]::Abs($p.B * $p.A - $q.B * $q.A) / 255)) {
        $sum += $d; if ($d -gt $max) { $max = [math]::Round($d) } }
    } }
    $mean = [math]::Round($sum / (4 * $x.Width * $x.Height), 1)
    # Monster pictures are shrunk to 64 px first. Windows' GDI+ (the scripts) fades the outermost pixels while
    # shrinking; the app's filter doesn't, so their edges differ a little. Every other picture must match exactly.
    if ($name -match 'npc') {
      if ($mean -le 16) { Add-Result $scenario $name "same picture" "shrunk with another filter: average difference $mean of 255 (max $max)" }
      else { Add-Result $scenario $name "DIFFERENT" "average difference $mean, max $max" }
    } elseif ($max -le 2) { Add-Result $scenario $name "same picture" "PNG encoded differently; max pixel difference $max" }
    else { Add-Result $scenario $name "DIFFERENT" "max pixel difference $max" }
  } finally { $x.Dispose(); $y.Dispose() }
}
function Compare-Trees([string]$scenario, [string]$ps, [string]$app) {
  $rel = { param($root) @(Get-ChildItem "$root\data" -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) }) }
  $names = @(& $rel $ps) + @(& $rel $app) + @("settings.json") | Sort-Object -Unique
  foreach ($n in $names) { if ((Test-Path "$ps\$n") -or (Test-Path "$app\$n")) { Compare-File $scenario $n "$ps\$n" "$app\$n" } }
  # Pictures downloaded during the scenario (not in the project's icons folder)
  $new = { param($root) @(Get-ChildItem "$root\icons" -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) } |
    Where-Object { -not (Test-Path "$Project\$_") -or $_ -match 'no-picture\.txt$' }) }
  foreach ($n in (@(& $new $ps) + @(& $new $app) | Sort-Object -Unique)) { Compare-File $scenario $n "$ps\$n" "$app\$n" }
}
function Compare-NotRecorded([string]$scenario, [string]$out) {
  $f = "$out\ps-not-recorded.txt"
  if (Test-Path $f) { $u = @([IO.File]::ReadAllLines($f) | Sort-Object -Unique); Add-Result $scenario "downloads" "DIFFERENT" "the scripts asked for $($u.Count) URL(s) the app didn't, e.g. $($u[0])" }
  else { Add-Result $scenario "downloads" "same" "the scripts asked for nothing the app didn't" }
}

# ================================================================= 1. GET answers on the real data
"1/4 GET answers on a copy of the real data..."
$A = "$Work\get-ps"; $B = "$Work\get-app"; $Tape = "$Work\tape-real"
New-Copy $A; New-Copy $B; Prepare-Ps $A
New-Item -ItemType Directory $Tape | Out-Null; [IO.File]::WriteAllText("$Tape\index.tsv", "", $Utf8)
# A few pictures removed from both copies, so both download and outline them again
# (an item with a collection log picture name, one known only to the bank's list, one with no name at all)
$clogImg = ([IO.File]::ReadAllText("$Project\data\clog\images.json") | ConvertFrom-Json).PSObject.Properties.Name
$bankImg = @(([IO.File]::ReadAllText("$Project\data\bank\items.json") | ConvertFrom-Json).PSObject.Properties | Where-Object { $_.Value[1] -and $clogImg -notcontains $_.Name } | ForEach-Object { $_.Name })
$probe = @(@(Get-Item "$Project\icons\item\$(@($clogImg | Where-Object { Test-Path "$Project\icons\item\$_.png" })[0]).png",
    "$Project\icons\item\$(@($bankImg | Where-Object { Test-Path "$Project\icons\item\$_.png" })[0]).png", "$Project\icons\item\0.png") +
  @(Get-ChildItem "$Project\icons\skill" -Filter *.png | Select-Object -First 1) +
  @(Get-ChildItem "$Project\icons\wiki" -Filter *.png | Where-Object { $_.BaseName -match "^[A-Za-z0-9_()'-]+$" } | Select-Object -First 1) |
  ForEach-Object { "$($_.Directory.Name)/$($_.BaseName)" })
foreach ($p in $probe) { foreach ($d in $A, $B) { Remove-Item "$d\icons\$p.png" } }
New-Item -ItemType Directory "$Work\out-get-app" | Out-Null
foreach ($p in $probe) { [void](Invoke-App $B "GET" "/icons/$p.png" "$Work\out-get-app\icon.png" $Tape) }
Invoke-Ps $A "get" $Tape "$Work\out-get-ps" ($probe -join ",")
foreach ($e in @("history", "clog", "bank", "miniquests", "diary-tasks", "quest-reqs", "ca-tasks", "ca-history", "progress", "plugin", "settings")) {
  [void](Invoke-App $B "GET" "/api/$e" "$Work\out-get-app\$e.json" $Tape)
  Compare-File "GET" "/api/$e" "$Work\out-get-ps\$e.json" "$Work\out-get-app\$e.json"
}
foreach ($p in $probe) { Compare-File "GET" "icons\$p.png" "$A\icons\$p.png" "$B\icons\$p.png" }
Compare-NotRecorded "GET" "$Work\out-get-ps"

# ================================================================= 2. Refresh on the real data, twice
"2/4 Refresh on a copy of the real data (the app downloads and records; the scripts replay)..."
$A = "$Work\refresh-ps"; $B = "$Work\refresh-app"
New-Copy $A; New-Copy $B; Prepare-Ps $A
foreach ($round in 1, 2) {
  $code = Invoke-App $B "POST" "/api/refresh" "$Work\out-refresh$round-app.json" $Tape
  Invoke-Ps $A "refresh" $Tape "$Work\out-refresh$round-ps"
  $st = [IO.File]::ReadAllText("$Work\out-refresh$round-ps\status.txt").Trim()
  Add-Result "Refresh $round" "status" $(if (($code -eq 0) -eq ($st -like "200*")) { "same" } else { "DIFFERENT" }) "app exit $code, scripts $st"
  Compare-Trees "Refresh $round" $A $B
  Compare-NotRecorded "Refresh $round" "$Work\out-refresh$round-ps"
}

if ($Fresh) {
  # =============================================================== 3. first start on an empty install
  "3/4 First start on an empty install (setup as $Player)..."
  $A = "$Work\fresh-ps"; $B = "$Work\fresh-app"; $Tape = "$Work\tape-fresh"
  New-Copy $A -Empty; New-Copy $B -Empty; Prepare-Ps $A
  $body = "{""player"":""$Player""}"
  $code = Invoke-App $B "POST" "/api/setup" "$Work\out-setup-app.json" $Tape $body
  Invoke-Ps $A "setup" $Tape "$Work\out-setup-ps" $body
  $st = [IO.File]::ReadAllText("$Work\out-setup-ps\status.txt").Trim()
  Add-Result "Setup" "status" $(if (($code -eq 0) -eq ($st -like "200*")) { "same" } else { "DIFFERENT" }) "app exit $code, scripts $st"
  Compare-Trees "Setup" $A $B
  Compare-NotRecorded "Setup" "$Work\out-setup-ps"
  if ($Wom) {
    # ============================================================= 4. Wise Old Man import after that setup
    "4/4 Wise Old Man import (the app downloads with the normal 3.5 s pauses)..."
    [void](Invoke-App $B "POST" "/api/wom" "$Work\out-wom-app.json" $Tape '{"import":true}')
    Invoke-Ps $A "wom" $Tape "$Work\out-wom-ps"
    $st = [IO.File]::ReadAllText("$Work\out-wom-ps\status.txt").Trim(); $ap = [IO.File]::ReadAllText("$Work\out-wom-app.json").Trim()
    Add-Result "Wise Old Man" "answer" $(if ($st -like "*$ap") { "same" } else { "DIFFERENT" }) "app $ap | scripts $st"
    # Backup file names carry the time of the run: compare their contents, not their names
    foreach ($d in $A, $B) { Get-ChildItem "$d\data" -Filter "history.backup-*.jsonl" | Rename-Item -NewName "history.backup.jsonl" }
    Compare-Trees "Wise Old Man" $A $B
    Compare-NotRecorded "Wise Old Man" "$Work\out-wom-ps"
  }
}

$results | Format-Table -AutoSize -Wrap scenario, what, result, note | Out-String -Width 200
$bad = @($results | Where-Object { $_.result -eq "DIFFERENT" }).Count
"{0} compared: {1} same bytes, {2} same data, {3} same picture, {4} DIFFERENT" -f $results.Count,
  @($results | Where-Object { $_.result -eq "same bytes" -or $_.result -eq "same" }).Count,
  @($results | Where-Object result -eq "same data").Count, @($results | Where-Object result -eq "same picture").Count, $bad
if (-not $Keep) { Remove-Item $Work -Recurse -Force } else { "Copies kept in $Work" }
if ($bad) { exit 1 }
