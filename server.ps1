# Local server for the OSRS dashboard.
# Serves the page and fetches the official hiscores ONLY when you press Refresh.
# Every refresh is saved to data\history.jsonl so progress can be tracked over time.

# Settings: settings.json next to this file, {"player": "Name", "womAsked": true|false}. Each person runs the
# dashboard for their own account. Without a name the page shows a setup card (POST /api/setup checks the name on
# the hiscores, then saves it); womAsked = the "Import from Wise Old Man?" offer was answered (POST /api/wom).
$Player   = ""
$WomAsked = $false
$SettingsFile = Join-Path $PSScriptRoot "settings.json"
if (Test-Path $SettingsFile) {
  try {
    $s = ([IO.File]::ReadAllText($SettingsFile)) | ConvertFrom-Json
    if ($s.player) { $Player = ([string]$s.player).Trim() }
    $WomAsked = [bool]$s.womAsked
  } catch { Write-Host "settings.json could not be read." }
}
function Save-Settings {
  $json = [ordered]@{ player = $script:Player; womAsked = $script:WomAsked } | ConvertTo-Json
  [IO.File]::WriteAllText($SettingsFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}
$Port     = 8765
$i = [array]::IndexOf($args, "-Port"); if ($i -ge 0) { $Port = [int]$args[$i + 1] }
$Cooldown = 60   # minimum seconds between hiscore requests

$Root        = $PSScriptRoot
$DataDir     = Join-Path $Root "data"
$HistoryFile = Join-Path $DataDir "history.jsonl"
# The player can be set while the server runs (setup), so the URL is made when it's needed
function Get-HiscoreUrl { "https://secure.runescape.com/m=hiscore_oldschool/index_lite.json?player=" + [uri]::EscapeDataString($script:Player) }
$Utf8        = New-Object System.Text.UTF8Encoding($false)
$LastFetch   = [datetime]::MinValue

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory $DataDir | Out-Null }

$Static = @{
  "/"           = @("index.html", "text/html; charset=utf-8")
  "/index.html" = @("index.html", "text/html; charset=utf-8")
  "/styles.css" = @("styles.css", "text/css; charset=utf-8")
  "/app.js"     = @("app.js",     "application/javascript; charset=utf-8")
  # Chart.js + fonts, saved once by tools\fetch-vendor.ps1 (nothing loads from the internet)
  "/vendor/chart.umd.min.js" = @("vendor\chart.umd.min.js", "application/javascript; charset=utf-8")
  "/vendor/fonts.css"        = @("vendor\fonts.css",        "text/css; charset=utf-8")
}

function Send($ctx, [int]$status, [string]$type, [string]$body) {
  $bytes = $Utf8.GetBytes($body)
  $ctx.Response.StatusCode = $status
  $ctx.Response.ContentType = $type
  $ctx.Response.Headers["Cache-Control"] = "no-store"
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}

function Send-Bytes($ctx, [string]$type, [byte[]]$bytes) {
  $ctx.Response.StatusCode = 200
  $ctx.Response.ContentType = $type
  $ctx.Response.Headers["Cache-Control"] = "max-age=2592000, immutable"   # icons never change
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}

# ---- in-memory response cache ----
# Pages and data are built once, kept in memory with a gzipped copy, and rebuilt only when the
# files behind them change. Browsers revalidate with ETag and get "304 Not Modified" (no body)
# when nothing changed, so a reload doesn't re-send the 5 MB history.
$Cache = @{}
function Get-Stamp([string[]]$files) {
  ($files | ForEach-Object { if (Test-Path $_) { $f = Get-Item $_; "$($f.Length).$($f.LastWriteTimeUtc.Ticks)" } else { "0" } }) -join "|"
}
function Get-Gzip([byte[]]$bytes) {
  $ms = New-Object IO.MemoryStream
  $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionLevel]::Optimal)
  $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
  return $ms.ToArray()
}
function Get-Cached([string]$key, [string[]]$files, [scriptblock]$build) {
  $stamp = Get-Stamp $files
  $c = $Cache[$key]
  if (-not $c -or $c.stamp -ne $stamp) {
    $bytes = $Utf8.GetBytes([string](& $build))
    $c = @{ stamp = $stamp; bytes = $bytes; gz = (Get-Gzip $bytes); etag = '"' + ("$key|$stamp").GetHashCode().ToString("x") + '"' }
    $Cache[$key] = $c
  }
  return $c
}
function Send-Cached($ctx, [string]$type, $c) {
  $req = $ctx.Request; $res = $ctx.Response
  $res.Headers["Cache-Control"] = "no-cache"   # always check, but reuse the browser's copy if unchanged
  $res.Headers["ETag"] = $c.etag
  $sent = "$($req.Headers['If-None-Match'])" -replace '^W/', '' -replace '"', ''
  if ($req.HttpMethod -eq "GET" -and $sent -eq ($c.etag -replace '"', '')) { $res.StatusCode = 304; $res.Close(); return }
  $body = $c.bytes
  if ("$($req.Headers['Accept-Encoding'])" -match "gzip") { $body = $c.gz; $res.Headers["Content-Encoding"] = "gzip" }
  $res.StatusCode = 200
  $res.ContentType = $type
  $res.ContentLength64 = $body.Length
  $res.OutputStream.Write($body, 0, $body.Length)
  $res.Close()
}

# Icons are downloaded once, outlined in white, saved to .\icons\<kind>\, and served locally after that.
. (Join-Path $Root "icon-outline.ps1")
. (Join-Path $Root "clog.ps1")   # collection log: names, categories, pictures, prices (items: plugin.ps1)
. (Join-Path $Root "progress.ps1")   # quests / diaries / combat tasks API (data: plugin.ps1 Update-PluginProgress)
. (Join-Path $Root "bank.ps1")   # bank value, prices, changes (contents: plugin.ps1 Get-PluginContainers)
. (Join-Path $Root "plugin.ps1")   # JSON export files from RuneLite ("OSRS Data Sync" format)
. (Join-Path $Root "wom.ps1")      # optional one-time import of older history from Wise Old Man (POST /api/wom)

function Read-Body($ctx) {
  $reader = New-Object IO.StreamReader($ctx.Request.InputStream, $Utf8)
  try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function ConvertTo-JsonString([string]$s) { ConvertTo-Json $s -Compress }
$IconDir     = Join-Path $Root "icons"
# Every picture is saved in .\icons (tools\fetch-all-icons.ps1 saves all items + monsters; the release ships them).
# The wiki is only asked for a picture that isn't saved yet (something new in the game), once: one it doesn't have
# is written to icons\no-picture.txt and never asked for again (no unnecessary requests).
$script:NoIconFile = Join-Path $IconDir "no-picture.txt"
$script:NoIcon = New-Object 'System.Collections.Generic.HashSet[string]'
if (Test-Path $script:NoIconFile) { foreach ($l in [IO.File]::ReadAllLines($script:NoIconFile)) { if ($l) { [void]$script:NoIcon.Add($l) } } }
# A failed download: the wiki has no such picture (404) -> remembered for good; anything else -> this run only
function Add-NoIcon([string]$key, $err) {
  [void]$script:NoIcon.Add($key)
  $code = try { [int]$err.Exception.Response.StatusCode } catch { 0 }
  if ($code -eq 404) { [IO.File]::AppendAllText($script:NoIconFile, "$key`r`n") }
}
# Special:Redirect/file follows renamed wiki files (e.g. "Teleport crystal (4).png" -> "Teleport crystal.png")
function Get-WikiFileUrl([string]$file) { "https://oldschool.runescape.wiki/w/Special:Redirect/file/" + [uri]::EscapeDataString(($file -replace ' ', '_')) }
$IconSources = @{
  "skill" = "{0}_icon.png"   # skill icons
  "wiki"  = "{0}.png"        # every other wiki picture (boss/clue icons too)
}
function Get-Icon([string]$kind, [string]$name) {
  $dir  = Join-Path $IconDir $kind
  $file = Join-Path $dir "$name.png"
  if (Test-Path $file) { return [IO.File]::ReadAllBytes($file) }
  if ($script:NoIcon.Contains("$kind/$name")) { return $null }   # the wiki doesn't have it: don't ask again
  $ProgressPreference = "SilentlyContinue"
  try {
    $res = Invoke-WebRequest -Uri (Get-WikiFileUrl ($IconSources[$kind] -f $name)) -UseBasicParsing -TimeoutSec 15
  } catch { Add-NoIcon "$kind/$name" $_; return $null }
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
  $bytes = Add-IconOutline $res.Content
  [IO.File]::WriteAllBytes($file, $bytes)
  Write-Host "Saved icon $kind/$name.png"
  return $bytes
}

function Get-History {
  if (-not (Test-Path $HistoryFile)) { return "[]" }
  $lines = [IO.File]::ReadAllText($HistoryFile, $Utf8).Split([char[]]"`r`n", [StringSplitOptions]::RemoveEmptyEntries)
  return "[" + [string]::Join(",", $lines) + "]"
}

# Daily snapshots: only the last 14 days keep every Refresh; older days keep just their last
# snapshot (end-of-day stats, so Today/month/year gains stay exact), plus the very first snapshot as the starting
# point. Days are game days (00:00 UTC reset to reset), like the page's periods. Lines before
# $UtcDaysFrom were already merged by LOCAL days and keep that grouping, so no saved snapshot of them is ever
# dropped by the switch. The first time, the full file is copied to history.before-daily-<date>.jsonl. Runs after
# each Refresh; the file is only rewritten when a day gets merged.
$KeepAllDays = 14
$UtcDaysFrom = [datetime]::new(2026, 10, 19, 0, 0, 0, [DateTimeKind]::Local)
function Compress-History {
  if (-not (Test-Path $HistoryFile)) { return }
  $lines = [IO.File]::ReadAllText($HistoryFile, $Utf8).Split([char[]]"`r`n", [StringSplitOptions]::RemoveEmptyEntries)
  $cutoff = (Get-Date).ToUniversalTime().Date.AddDays(-$KeepAllDays)
  $keep = New-Object System.Collections.Generic.List[string]
  # Day of each line: "U<UTC date>" (game day), or "L<local date>" for lines merged before the switch
  $days = @(foreach ($l in $lines) {
    $t = [datetime]::Parse($l.Substring(6, $l.IndexOf('"', 6) - 6)).ToLocalTime()
    if ($t -lt $UtcDaysFrom) { "L" + $t.ToString("yyyy-MM-dd") } else { "U" + $t.ToUniversalTime().ToString("yyyy-MM-dd") }
  })
  $cutoffKey = "U" + $cutoff.ToString("yyyy-MM-dd")
  for ($i = 0; $i -lt $lines.Count; $i++) {
    # Older day: only its last snapshot (the next line is another day)
    if ($i -eq 0 -or ($days[$i][0] -eq "U" -and $days[$i] -ge $cutoffKey) -or $i -eq $lines.Count - 1 -or $days[$i + 1] -ne $days[$i]) { $keep.Add($lines[$i]) }
  }
  if ($keep.Count -eq $lines.Count) { return }
  if (-not (Get-ChildItem $DataDir -Filter "history.before-daily-*.jsonl")) {
    Copy-Item $HistoryFile (Join-Path $DataDir "history.before-daily-$((Get-Date).ToString('yyyyMMdd')).jsonl")
  }
  $tmp = "$HistoryFile.tmp"
  [IO.File]::WriteAllText($tmp, [string]::Join("`n", $keep) + "`n", $Utf8)
  Move-Item $tmp $HistoryFile -Force
  Write-Host "History: merged older days into daily snapshots ($($lines.Count) -> $($keep.Count) snapshots)"
}

# A Refresh downloads the hiscores and GE prices at the same time (Get-Web reads the results from $Prefetch).
Add-Type -AssemblyName System.Net.Http
$Http = New-Object System.Net.Http.HttpClient
$Http.Timeout = [TimeSpan]::FromSeconds(30)
function Start-Get([string]$url, [string]$ua) {
  $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
  [void]$req.Headers.TryAddWithoutValidation("User-Agent", $ua)
  return $Http.SendAsync($req)
}
# Waits for a download started by Start-Get: @(HTTP status, body); status 0 = no connection
function Get-Done($task) {
  try { $res = $task.GetAwaiter().GetResult() } catch { return @(0, $null) }
  return @([int]$res.StatusCode, $res.Content.ReadAsStringAsync().GetAwaiter().GetResult())
}

function Invoke-Refresh {
  if (-not $script:Player) { return @(400, "{""error"":""Set up your player name first.""}") }
  $wait = $Cooldown - ((Get-Date) - $script:LastFetch).TotalSeconds
  if ($wait -gt 0) { return @(429, "{""error"":""Please wait $([math]::Ceiling($wait))s before refreshing again.""}") }
  $script:LastFetch = Get-Date
  $started = Get-Date
  $HiscoreUrl = Get-HiscoreUrl
  $jobs = [ordered]@{
    $HiscoreUrl       = Start-Get $HiscoreUrl "Mozilla/5.0 (Windows NT 10.0; Win64; x64) WindowsPowerShell/5.1"
    $PricesUrl        = Start-Get $PricesUrl $ClogUA   # GE prices now, for the bank's "Price moves today"
  }
  # GE prices on the days the periods start, for price moves per period (only days not on disk yet)
  $pastUrls = @(try { Get-BankPastUrls } catch { })
  foreach ($u in $pastUrls) { $jobs[$u] = Start-Get $u $ClogUA }
  $got = @{}
  foreach ($url in $jobs.Keys) { $got[$url] = Get-Done $jobs[$url] }

  $code, $body = $got[$HiscoreUrl]
  if ($code -eq 404) {
    $script:LastFetch = (Get-Date).AddSeconds(5 - $Cooldown)   # a mistyped name can be retried after 5 s
    return @(404, "{""error"":""'$($Player -replace '[\\"]', '')' isn't on the OSRS hiscores. Check the spelling (accounts need some XP to be listed).""}")
  }
  if ($code -ne 200) { return @(502, "{""error"":""Could not reach the OSRS hiscores. Try again later.""}") }
  $data = ($body -replace "[\r\n]", "").Trim()
  $time = (Get-Date).ToUniversalTime().ToString("o")
  [IO.File]::AppendAllText($HistoryFile, "{""t"":""$time"",""d"":$data}`n", $Utf8)
  Write-Host "[$(Get-Date -Format T)] Saved hiscores snapshot (all sites answered in $([int]((Get-Date) - $started).TotalMilliseconds) ms)"
  try { Compress-History } catch { Write-Host "History merge failed: $($_.Exception.Message)" }

  # Everything else comes from the OSRS Data Sync plugin's files on this PC (plugin.ps1); the old
  # sources (other RuneLite plugins and sites) are not used at all.
  # Failures here never block the refresh. Names, pictures and GE prices still come from the OSRS Wiki.
  $script:Prefetch = @{}
  foreach ($url in @($PricesUrl) + $pastUrls) { if ($got[$url][0] -eq 200) { $script:Prefetch[$url] = $got[$url][1] } }
  try { Write-Host "[$(Get-Date -Format T)] $(Update-PluginProgress)" } catch { Write-Host "Progress failed: $($_.Exception.Message)" }
  # Kills + drops the Drop log is missing (played without the plugin), from the Loot Tracker totals (plugin.ps1).
  # Before the collection log: it counts log items among those drops too.
  try { Write-Host "[$(Get-Date -Format T)] $(Update-PluginLootGaps)" } catch { Write-Host "Drop log gaps failed: $($_.Exception.Message)" }
  try { Write-Host "[$(Get-Date -Format T)] $(Update-PluginClog)" } catch { Write-Host "Collection log failed: $($_.Exception.Message)" }
  try { Write-Host "[$(Get-Date -Format T)] $(Update-Bank)" } catch { Write-Host "Bank failed: $($_.Exception.Message)" }
  # Kill totals from the OSRS Data Sync plugin's file, for the Recent activity feed (plugin.ps1)
  try { Write-Host "[$(Get-Date -Format T)] $(Update-PluginKills $time)" } catch { Write-Host "Plugin kills failed: $($_.Exception.Message)" }
  $script:Prefetch = $null
  Write-Host "[$(Get-Date -Format T)] Refresh done in $([int]((Get-Date) - $started).TotalMilliseconds) ms"
  return @(200, $null)   # the route sends the (cached) history
}

# Listen on the whole home network (for the phone) when tools\enable-phone-access.ps1
# has reserved the URL; otherwise only this PC can reach it.
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
try { $listener.Start(); $lan = $true }
catch {
  $lan = $false
  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add("http://localhost:$Port/")
  $listener.Start()
}
Write-Host "OSRS dashboard running at http://localhost:$Port/  ($(if ($Player) { "player: $Player" } else { "not set up yet: enter your OSRS name on the page" }))"
if ($lan) {
  $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254*" } | ForEach-Object { $_.IPAddress }
  foreach ($ip in $ips) { Write-Host "On your phone (same Wi-Fi): http://${ip}:$Port/" -ForegroundColor Green }
}
Write-Host "Close this window to stop it."
if ($args -notcontains "-NoBrowser") { Start-Process "http://localhost:$Port/" }

try {
  while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(500)) { }   # lets Ctrl+C work
    $ctx  = $task.Result
    $path = $ctx.Request.Url.AbsolutePath
    try {
      if ($path -eq "/api/history" -and $ctx.Request.HttpMethod -eq "GET") {
        Send-Cached $ctx "application/json" (Get-Cached "history" @($HistoryFile) { Get-History })
      } elseif ($path -eq "/api/refresh" -and $ctx.Request.HttpMethod -eq "POST") {
        $r = Invoke-Refresh
        if ($r[0] -eq 200) { Send-Cached $ctx "application/json" (Get-Cached "history" @($HistoryFile) { Get-History }) }
        else { Send $ctx $r[0] "application/json" $r[1] }
      } elseif ($path -eq "/api/clog" -and $ctx.Request.HttpMethod -eq "GET") {
        $files = "history.jsonl", "items.json", "categories.json", "prices.json" | ForEach-Object { Join-Path $ClogDir $_ }
        Send-Cached $ctx "application/json" (Get-Cached "clog" $files { Get-ClogJson })
      } elseif ($path -eq "/api/bank" -and $ctx.Request.HttpMethod -eq "GET") {
        $files = "history.jsonl", "items.json", "prices.json", "mapping.json", "derived.json", "slots.json", "gear.json", "prices-live.json", "prices-reset.json", "prices-past.json", "prices-days.json", "prices-saves.jsonl" | ForEach-Object { Join-Path $BankDir $_ }
        Send-Cached $ctx "application/json" (Get-Cached "bank" $files { Get-BankJson })
      } elseif ($path -eq "/api/miniquests" -and $ctx.Request.HttpMethod -eq "GET") {
        Send-Cached $ctx "application/json" (Get-Cached "miniquests" @(Join-Path $ProgressDir "miniquests.json") { Get-MiniquestsJson })
      } elseif ($path -eq "/api/diary-tasks" -and $ctx.Request.HttpMethod -eq "GET") {
        Send-Cached $ctx "application/json" (Get-Cached "diary-tasks" @(Join-Path $ProgressDir "diary-tasks.json") { Get-DiaryTasksJson })
      } elseif ($path -eq "/api/quest-reqs" -and $ctx.Request.HttpMethod -eq "GET") {
        Send-Cached $ctx "application/json" (Get-Cached "quest-reqs" @(Join-Path $ProgressDir "quest-reqs.json") { Get-QuestReqsJson })
      } elseif ($path -eq "/api/ca-tasks" -and $ctx.Request.HttpMethod -eq "GET") {
        Send-Cached $ctx "application/json" (Get-Cached "ca-tasks" @(Join-Path $ProgressDir "ca-tasks.json") { Get-CaTasksJson })
      } elseif ($path -eq "/api/ca-history" -and $ctx.Request.HttpMethod -eq "GET") {
        Send-Cached $ctx "application/json" (Get-Cached "ca-history" @(Join-Path $ProgressDir "history.jsonl") { Get-CaHistoryJson })
      } elseif ($path -eq "/api/settings" -and $ctx.Request.HttpMethod -eq "GET") {
        # womOffer: show the "Import from Wise Old Man?" banner (not answered yet and nothing imported)
        $offer = [bool]$Player -and -not $WomAsked -and -not (Test-WomImported $HistoryFile)
        Send $ctx 200 "application/json" ([ordered]@{ player = $(if ($Player) { $Player } else { $null }); womOffer = $offer } | ConvertTo-Json -Compress)
      } elseif ($path -eq "/api/setup" -and $ctx.Request.HttpMethod -eq "POST") {
        # First start: {"player": "Name"}. Checked on the hiscores (that request is the first Refresh), then saved.
        # Only while no name is set, so one install never mixes two accounts' history.
        $name = try { ([string]((Read-Body $ctx) | ConvertFrom-Json).player).Trim() } catch { "" }
        if ($Player) { Send $ctx 409 "application/json" "{""error"":""This dashboard is already set up for $(($Player -replace '[\\"]', '')). Edit settings.json to change it.""}" }
        elseif ($name -notmatch '^[A-Za-z0-9 _-]{1,12}$') { Send $ctx 400 "application/json" "{""error"":""OSRS names are 1-12 letters, numbers, spaces, - or _.""}" }
        else {
          $script:Player = $name
          $r = Invoke-Refresh
          if ($r[0] -eq 200) {
            $script:WomAsked = $false
            Save-Settings
            Write-Host "Set up for $Player (saved in settings.json)"
            Send-Cached $ctx "application/json" (Get-Cached "history" @($HistoryFile) { Get-History })
          } else {
            $script:Player = ""   # not found / no connection: nothing saved, try again
            if ($r[0] -eq 502) { $script:LastFetch = (Get-Date).AddSeconds(5 - $Cooldown) }
            Send $ctx $r[0] "application/json" $r[1]
          }
        }
      } elseif ($path -eq "/api/wom" -and $ctx.Request.HttpMethod -eq "POST") {
        # The Wise Old Man offer: {"import": true} imports older history once, {"import": false} = no thanks.
        # Either way it's never offered again (tools\import-wom.ps1 can still do it later).
        $want = try { [bool]((Read-Body $ctx) | ConvertFrom-Json).import } catch { $false }
        if (-not $Player) { Send $ctx 400 "application/json" "{""error"":""Set up your player name first.""}" }
        elseif (-not $want) { $script:WomAsked = $true; Save-Settings; Send $ctx 200 "application/json" "{""message"":null}" }
        else {
          try {
            $r = Import-WomHistory $Player $HistoryFile
            $script:WomAsked = $true; Save-Settings
            $msg = "Imported $($r.kept) snapshots from Wise Old Man ($(([datetime]$r.from).ToString('MMM d, yyyy')) to $(([datetime]$r.to).ToString('MMM d, yyyy')))."
            Write-Host $msg
            Send $ctx 200 "application/json" "{""message"":$(ConvertTo-JsonString $msg)}"
          } catch {
            $msg = $_.Exception.Message
            # Nothing on Wise Old Man for this name: answered, don't offer again. Busy / offline: offer again later.
            if ($msg -match "doesn't track|no snapshots|already imported") { $script:WomAsked = $true; Save-Settings }
            Send $ctx 422 "application/json" "{""error"":$(ConvertTo-JsonString $msg)}"
          }
        }
      } elseif ($path -eq "/api/plugin" -and $ctx.Request.HttpMethod -eq "GET") {
        Send-Cached $ctx "application/json" (Get-Cached "plugin" @(Get-PluginFiles) { Get-PluginJson })
      } elseif ($path -eq "/api/progress" -and $ctx.Request.HttpMethod -eq "GET") {
        Send-Cached $ctx "application/json" (Get-Cached "progress" @(Join-Path $ProgressDir "latest.json") { Get-ProgressJson })
      } elseif ($path -match '^/icons/item/([0-9]+)\.png$') {
        $bytes = Get-ItemIcon $Matches[1]
        if ($bytes) { Send-Bytes $ctx "image/png" $bytes } else { Send $ctx 404 "text/plain" "Icon not found" }
      } elseif ($path -match '^/icons/npc/([a-z0-9-]+)\.png$') {
        # Monster pictures for Kills & loot: saved on Refresh (plugin.ps1 Update-NpcIcons), served from disk only
        $file = Join-Path $IconDir "npc\$($Matches[1]).png"
        if (Test-Path $file) { Send-Bytes $ctx "image/png" ([IO.File]::ReadAllBytes($file)) } else { Send $ctx 404 "text/plain" "Icon not found" }
      } elseif ($path -match '^/icons/ca/([a-z0-9]+)\.png$') {
        # Combat achievement monster icons: made once by tools\fetch-ca-icons.ps1, served from disk only
        $file = Join-Path $IconDir "ca\$($Matches[1]).png"
        if (Test-Path $file) { Send-Bytes $ctx "image/png" ([IO.File]::ReadAllBytes($file)) } else { Send $ctx 404 "text/plain" "Icon not found" }
      } elseif ([uri]::UnescapeDataString($path) -match "^/icons/(skill|wiki)/([A-Za-z0-9_()'-]+)\.png$") {
        # Every icon comes from the OSRS Wiki (' is in names like Vet'ion)
        $bytes = Get-Icon $Matches[1] $Matches[2]
        if ($bytes) { Send-Bytes $ctx "image/png" $bytes } else { Send $ctx 404 "text/plain" "Icon not found" }
      } elseif ($path -match '^/vendor/fonts/([a-z0-9-]+)\.woff2$') {
        $file = Join-Path $Root "vendor\fonts\$($Matches[1]).woff2"
        if (Test-Path $file) { Send-Bytes $ctx "font/woff2" ([IO.File]::ReadAllBytes($file)) } else { Send $ctx 404 "text/plain" "Font not found" }
      } elseif ($Static.ContainsKey($path)) {
        $file = Join-Path $Root $Static[$path][0]
        Send-Cached $ctx $Static[$path][1] (Get-Cached $file @($file) { [IO.File]::ReadAllText($file, $Utf8) })
      } else {
        Send $ctx 404 "text/plain" "Not found"
      }
    } catch {
      Write-Host "Error: $_"
      try { Send $ctx 500 "application/json" "{""error"":""Server error""}" } catch { }
    }
  }
} finally {
  $listener.Stop()
}
