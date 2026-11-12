# OSRS Progress Dashboard

A progress dashboard app for your own Old School RuneScape account, for Windows and Mac. It combines the official
hiscores with JSON files exported from RuneLite on your computer, turns them into readable charts and lists, and keeps
the full history on your computer.

![Dashboard overview](docs/dashboard.png)

## Download

| Package | Platform | Link |
| --- | --- | --- |
| Desktop app installer | Windows 10/11 | [OSRS-Dashboard-Setup.exe](https://github.com/slappingpikachu/runescape-dashboard/releases/latest/download/OSRS-Dashboard-Setup.exe) |
| Desktop app disk image | macOS 11 or later, Apple silicon (M1 and newer) | [OSRS-Dashboard-Mac.dmg](https://github.com/slappingpikachu/runescape-dashboard/releases/latest/download/OSRS-Dashboard-Mac.dmg) |

These links always point to the latest version. Release notes and earlier versions are on the
[Releases](https://github.com/slappingpikachu/runescape-dashboard/releases) page.

## Features

- **XP and levels**: gains per skill for any period, a total XP chart, per-day bars and skill comparisons.
- **Bosses and clues**: kill counts and clue completions from the hiscores, with gains per period.
- **Bank**: value over time, equipment, inventory and storage items (looting bag, seed vault, tackle box and more),
  item changes between saves, price movements, and Grand Exchange offers with after-tax results against the GE price.
- **Collection log**: slots, value, recent additions with their sources, every page of the in-game log, and pets.
- **Kills and loot**: every source in RuneLite's Loot Tracker, with loot totals and a searchable drop log.
- **Quests, diaries and combat achievements**: completion status, requirements, and task lists with each completed
  diary task marked.
- **Recent activity**: a feed of every update, a 16-week heatmap and streaks.
- **Sync**: keep two computers the same automatically through your own Google Drive, a shared folder, or by
  exporting and importing a file; both keep every snapshot.

Every view can be set to any period from one day to all time. Charts and periods follow the game's daily reset
(00:00 UTC); the activity feed and drop log are grouped by your calendar day.

## Requirements

- Windows 10 or 11, or macOS 11 or later on Apple silicon (M1 and newer).
- For bank, collection log, quests, diaries, combat achievements, kills and loot: RuneLite exporting JSON files to
  `.runelite/plugin-data/osrsdatasync/<player>/`. This is the format of the OSRS Data Sync plugin on RuneLite's
  Plugin Hub. Keep RuneLite's built-in **Loot Tracker** plugin enabled for kills and loot. Without these files, the
  dashboard shows hiscores data only.

## Installation

- **Windows:** run [OSRS-Dashboard-Setup.exe](#download); it installs without administrator rights. The app is not
  code-signed, so on first launch Windows SmartScreen shows a warning: select **More info**, then **Run anyway**.
- **Mac:** open [OSRS-Dashboard-Mac.dmg](#download) and drag **OSRS Dashboard** into **Applications**. The app is not
  code-signed, so the first time macOS says it can't check it: select **Done**, open **System Settings → Privacy &
  Security**, scroll down, select **Open Anyway** next to "OSRS Dashboard" and confirm. (macOS 14 and older:
  right-click the app, select **Open**, then **Open** again.)

| | Windows | Mac |
| --- | --- | --- |
| Data | `%APPDATA%\OSRS Dashboard\` | `~/Library/Application Support/OSRS Dashboard/` |

- To use an existing dashboard folder instead (for example one from the former PowerShell version), create a file
  named `root.txt` in the data folder containing that folder's path.
- To update, install the new version over the old one. Your data stays.
- To move your history to a second computer, or keep two computers the same, use [Sync](#using-two-computers).

Build instructions for Windows and macOS are in [app/README.md](app/README.md).

## First run

1. Enter your OSRS name. The dashboard verifies it on the hiscores, saves it to `settings.json` and takes the first
   snapshot.
2. With **Import Wise Old Man History** ticked, your earlier history is imported once if your account is tracked
   there.
3. In RuneLite, log in, open your bank once, then open the collection log and select **Search** once, so the JSON
   files include everything.
4. Select **Update** on the dashboard.

## Data sources

Data is only fetched when you select **Update**, at most once per minute.

| Source | Used for |
| --- | --- |
| Official OSRS hiscores | Levels, XP, ranks, boss kills, clue completions and collection log slots |
| JSON files on your computer | Quests, diaries, combat achievements, collection log, bank, equipment, storage items, Grand Exchange offers, kills and loot |
| OSRS Wiki | GE prices for items you own or have owned, and names and images for new items |
| Wise Old Man | The optional one-time history import |
| Google Drive | Only if you connect it: your sync file, in the app's own hidden folder ([Using two computers](#using-two-computers)) |

No other services are contacted. Nothing is uploaded unless you connect Google Drive.

Each update adds a snapshot to `data\history.jsonl`. Snapshots from the last 14 days are kept in full; older
snapshots are combined into one per game day, which keeps daily gains intact. Update at least once a day for
accurate daily figures.

## Using two computers

If you play on more than one computer (for example a Windows PC and a Mac), select **Sync** next to **Update** to
keep both dashboards' history the same.

**Automatically, with Google Drive.** Select **Connect Google Drive** once on each computer and sign
in to Google in your browser, with the same Google account on both. From then on, every **Update** first merges the
other computer's newer history, then saves this computer's, and opening the app merges too. No Google Drive app is
needed. The app can only use its own hidden folder in your Drive; it can't see your other files. Select
**Disconnect Google Drive** to stop. See the [privacy policy](https://slappingpikachu.github.io/runescape-dashboard/privacy.html).

**Automatically, with a shared folder.** Select **Other Folder…** and enter a folder that both computers keep in
sync (OneDrive, Dropbox, a network drive). Every **Update** works the same as with Google Drive.

**By hand.**

1. On the computer you just played on, select **Export**. A `.osrssync` file is saved to your Downloads folder.
2. Move the file to the other computer (AirDrop, USB stick, or email it to yourself).
3. On the other computer, select **Sync**, then **Import File…**, and pick the file.

A sync merges; it never replaces. Every snapshot from both computers is kept and sorted by time: hiscores, bank,
quests, diaries, combat achievements, collection log, kill totals and the drop log. RuneLite's current files (Kills
& loot, Grand Exchange offers, storage items) come along too, and each computer shows the newer ones, so a computer
you don't play on stays up to date. Settings, prices and images stay per computer. The files as they were before an
import are kept in `data\sync\backup-<time>\` (the newest three).

- Both computers must be set up for the same OSRS name. Log in to the same RuneLite account on both, so RuneLite's
  Loot Tracker totals are shared.
- Kills you make on one computer appear on the other only after a sync. Until then, the other computer may list
  them as played without the plugin; the sync removes those entries again.
- After an import, an **Update** skips this computer's RuneLite files when they are older than what the other
  computer sent (RuneLite hasn't run here since), so older quests or an older bank never replace newer ones. Once
  RuneLite runs on this computer again, its files count as usual.

## Data files

All in the app's data folder ([Installation](#installation)).

| Path | Contents |
| --- | --- |
| `settings.json` | Your OSRS name and setup choices |
| `data\history.jsonl` | Hiscores snapshots (XP, kills and ranks history) |
| `data\bank\` | Bank history, item names and prices |
| `data\clog\` | Collection log history, item data, prices and layout |
| `data\progress\` | Quest, diary and combat achievement history and task lists |
| `data\plugin\` | Kill totals per update, drop log gaps, drops imported from your other computer, monster images |
| `data\sync\` | This computer's sync state and backups from before each import |
| `icons\` | Item, boss and monster images from the OSRS Wiki |

Back up the `data` folder to keep your history.

## Maintenance tools

These rebuild the reference lists in this repository from the OSRS Wiki when new content is released (developers
only; the app doesn't need them). Run them from the repository folder with
`powershell -ExecutionPolicy Bypass -File tools\<name>.ps1` on Windows, or `pwsh tools/<name>.ps1` on a Mac
(`brew install powershell`).

| Tool | Purpose |
| --- | --- |
| `fetch-clog-layout.ps1` | Collection log tabs, pages and items |
| `fetch-ca.ps1`, `fetch-ca-icons.ps1` | Combat achievement tasks and monster images |
| `fetch-diaries.ps1` | Achievement diary tasks and requirements |
| `fetch-quests.ps1` | Quest requirements |
| `fetch-all-icons.ps1` | All item, monster and NPC images (resumable) |

## Development

| Path | Contents |
| --- | --- |
| `index.html`, `styles.css`, `app.js`, `vendor\` | The dashboard page |
| `app\` | The app (Tauri and Rust): data processing, sync, Google Drive. Build and release: [app/README.md](app/README.md) |
| `tools\` | Maintenance tools (above) |
| `docs\` | The project's web page and privacy policy (GitHub Pages) |

The PowerShell version of the dashboard was retired in version 0.4.2; the app reads and writes the same data files.
