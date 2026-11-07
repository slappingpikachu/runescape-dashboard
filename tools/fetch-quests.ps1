# Download of every quest's and miniquest's requirements from the OSRS Wiki (its "Quest details" box), saved to
# data\progress\quest-reqs.json. About 6 requests (50 pages each). Reference data: rerun when Jagex adds quests.
#   powershell -ExecutionPolicy Bypass -File tools\fetch-quests.ps1
#
# quest-reqs.json: {"<quest name>": {"skills": [[skill, level, boostable]], "quests": [[quest name, depth]],
#                   "qp": n, "combat": n, "extra": [text], "items": [text], "reward": quest points given}}
# Names use RuneLite's spelling for Recipe for Disaster parts ("Recipe for Disaster - Pirate Pete"); everything else
# is the wiki page title. The page matches names with punctuation and case ignored (The Writing's / Writings).
# "quests" is the prerequisite tree in wiki order: depth 0 = needed directly, 1 = needed by the one above, ...
$Root = Split-Path $PSScriptRoot -Parent
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$UA   = "osrs-progress-dashboard/1.0 (self-hosted OSRS progress dashboard)"
$Api  = "https://oldschool.runescape.wiki/api.php"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-WikiJson([string]$query) {
  $res = Invoke-WebRequest -Uri "$Api`?$query&format=json&formatversion=2" -UseBasicParsing -TimeoutSec 30 -UserAgent $UA
  return [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray()) | ConvertFrom-Json
}

# Wiki markup -> plain text (same rules as fetch-diaries.ps1)
function Clean([string]$s) {
  $s = $s -replace '(?s)<ref[^>]*/>', '' -replace '(?s)<ref[^>]*>.*?</ref>', ''
  $s = [regex]::Replace($s, '\{\{SCP\|([^|}]+)\|([^|}]+)[^}]*\}\}', { param($m) "$($m.Groups[2].Value) $($m.Groups[1].Value)" })
  $s = $s -replace '\{\{SCP\|[^}]*\}\}', '' -replace '\{\{NA\|([^}]*)\}\}', '$1'
  $s = $s -replace '\{\{Fairycode\|([^|}]+)[^}]*\}\}', '$1'
  $s = $s -replace '\{\{[^{}]*\}\}', ''
  $s = $s -replace '\[\[(?:[^\]|]*\|)?([^\]]*)\]\]', '$1' -replace "'''?", '' -replace '<[^>]+>', ''
  $s = $s -replace '\[https?://\S+ ([^\]]*)\]', '$1'
  $s = $s -replace '\(\s*\)', ''
  return ($s -replace '[ \t]+', ' ').Trim()
}

# Wiki page title -> the name used here (RuneLite's spelling for Recipe for Disaster parts)
function Get-QuestName([string]$title) {
  $t = ($title -replace '_', ' ' -replace '#.*$', '').Trim()
  $t = $t -replace ' \((miniquest|quest)\)$', ''
  if ($t -match '^Recipe for Disaster/(.+)$') {
    $part = $Matches[1]
    if ($part -match 'Goblin generals') { return "Recipe for Disaster - Wartface & Bentnoze" }
    $part = $part -replace '^(Freeing|Defeating) ', '' -replace '^the ', ''
    return "Recipe for Disaster - $part"
  }
  return $t
}

# One field of the "Quest details" box, up to the next field
function Get-Field([string]$wikitext, [string]$field) {
  $m = [regex]::Match($wikitext, "(?s)\n\|\s*$field\s*=(.*?)(?=\n\|\s*\w+\s*=|\n\}\})")
  if ($m.Success) { return $m.Groups[1].Value } else { return "" }
}

# 1. Every quest and miniquest page (guides and list pages left out)
$titles = @()
foreach ($cat in "Quests", "Miniquests") {
  $j = Get-WikiJson "action=query&list=categorymembers&cmtitle=Category:$cat&cmnamespace=0&cmlimit=500"
  $titles += $j.query.categorymembers.title | Where-Object { $_ -notmatch '/(Quick|Full) guide$' -and $_ -notin "Quests", "Miniquests" }
}
$titles = @($titles | Sort-Object -Unique)
$known = @{}; foreach ($t in $titles) { $known[(Get-QuestName $t)] = $true }
Write-Host "$($titles.Count) quest pages"

# 2. Their wikitext, 50 pages per request
$out = [ordered]@{}
for ($i = 0; $i -lt $titles.Count; $i += 50) {
  $batch = $titles[$i..([Math]::Min($i + 49, $titles.Count - 1))]
  $q = ($batch | ForEach-Object { [uri]::EscapeDataString($_) }) -join '|'
  $j = Get-WikiJson "action=query&prop=revisions&rvprop=content&rvslots=main&titles=$q"
  foreach ($page in $j.query.pages) {
    $w = $page.revisions[0].slots.main.content
    if (-not $w -or $w -notmatch '\{\{Quest details') { continue }
    $skills = @(); $quests = @(); $extra = @(); $items = @(); $qp = 0; $combat = 0
    foreach ($line in (Get-Field $w 'requirements') -split "`n") {
      $m = [regex]::Match($line.Trim(), '^(\*+)\s*(.*)$')
      $depth = if ($m.Success) { $m.Groups[1].Value.Length } else { 0 }
      $text = if ($m.Success) { $m.Groups[2].Value } else { $line }
      if (-not $text.Trim()) { continue }
      $scp = [regex]::Matches($text, '\{\{SCP\|([^|}]+)\|([0-9,]+)[^}]*\}\}')
      if ($scp.Count -gt 0) {
        foreach ($s in $scp) {
          $name = $s.Groups[1].Value.Trim(); $lvl = [int]($s.Groups[2].Value -replace ',', '')
          if ($name -eq "Quest") { $qp = [Math]::Max($qp, $lvl) }
          elseif ($name -eq "Combat") { $combat = [Math]::Max($combat, $lvl) }
          else { $skills += , @($name, $lvl, ($text -notmatch 'Boostable\|no')) }
        }
        continue
      }
      $link = [regex]::Match($text, '^\s*\[\[([^\]|]+)')
      if ($link.Success -and $known.ContainsKey((Get-QuestName $link.Groups[1].Value))) {
        $quests += , @((Get-QuestName $link.Groups[1].Value), $depth)
        continue
      }
      if ($text -match '(?i)completion of|the following quests') { continue }
      $c = Clean $text
      if ($c -and $c -notmatch '^(None|N/A)\.?$') { $extra += $c }
    }
    if ($quests.Count) {   # depth relative to the direct prerequisites
      $min = ($quests | ForEach-Object { $_[1] } | Measure-Object -Minimum).Minimum
      $quests = @($quests | ForEach-Object { , @($_[0], ($_[1] - $min)) })
    }
    foreach ($line in (Get-Field $w 'items') -split "`n") {
      $c = Clean ($line.Trim() -replace '^\*+\s*', '')
      if ($c -and $c -notmatch '^(None|N/A)\.?$') { $items += $c }
    }
    # Quest points the quest gives ("Quest rewards" box), so the page can add up yours from finished quests
    $rm = [regex]::Match($w, '(?s)\{\{Quest rewards.*?\|\s*qp\s*=\s*(\d+)')
    $reward = if ($rm.Success) { [int]$rm.Groups[1].Value } else { 0 }
    if ($page.title -eq "Recipe for Disaster") { $reward = 0 }   # its 10 points are on the 10 subquests
    $out[(Get-QuestName $page.title)] = [ordered]@{ skills = $skills; quests = $quests; qp = $qp; combat = $combat; extra = $extra; items = $items; reward = $reward }
  }
}

$sorted = [ordered]@{}; foreach ($k in ($out.Keys | Sort-Object)) { $sorted[$k] = $out[$k] }
$file = Join-Path $Root "data\progress\quest-reqs.json"
[IO.File]::WriteAllText($file, ($sorted | ConvertTo-Json -Compress -Depth 6), $Utf8)
Write-Host "Saved $($sorted.Count) quests to $file"
