# OSRS Dashboard app

The dashboard for Windows and macOS, made with [Tauri 2](https://tauri.app). It shows the page in `index.html`,
`app.js` and `styles.css`, and handles the page's requests in Rust (`src-tauri/src/server.rs`): updates, data files,
sync and Google Drive. The data files keep the format of the former PowerShell version, so its data folders work as
they are. It opens no network port, except for a moment while you connect Google Drive (below).

## Data location

| | Windows | macOS |
| --- | --- | --- |
| Program | `%LOCALAPPDATA%\OSRS Dashboard\` | `/Applications/OSRS Dashboard.app` |
| Data | `%APPDATA%\OSRS Dashboard\` | `~/Library/Application Support/OSRS Dashboard/` |

The data folder is kept when the app is uninstalled. On first launch, the shared reference lists (collection log
layout, task lists, item mapping) are copied into it; existing files are not replaced.

To use an existing dashboard folder, put its path in a file named `root.txt` in the data folder, or start the app
with `--root <folder>`.

## Network access

The app contacts the official hiscores, the OSRS Wiki and its price API, and Wise Old Man (import only), and only
when you update or import. All other hosts are blocked in `src-tauri/src/net.rs`. The one exception is Google Drive
sync, which is off until you connect it (next section). JSON export files are read from
`~/.runelite/plugin-data/osrsdatasync/`.

## Google Drive sync

**Sync → Connect Google Drive** (once per computer) opens Google's sign-in page in your browser. Google then sends
the browser back to a one-time address on this computer (`http://127.0.0.1:<port>`, open only during the sign-in)
to hand over the access. After that, every Update downloads your other computer's newer sync file, merges it, and
uploads this computer's file. Opening the app merges too. The files live in the app's own hidden folder in your
Drive (permission `drive.appdata`): the app can't see your other Drive files. The sign-in is kept in
`data/sync/google.json` on that computer only. **Disconnect Google Drive** forgets and revokes it. Code:
`src-tauri/src/gdrive.rs` (Google) and `src-tauri/src/sync.rs` (what is merged). Privacy policy:
<https://slappingpikachu.github.io/runescape-dashboard/privacy.html>.

The Google sign-in needs an OAuth client ("Desktop app") from Google Cloud. `build.rs` builds it in from
`src-tauri/google-client.json`, which is gitignored. Without that file the app is built without Google Drive; folder
sync and Export/Import still work.

## Releases

`.github/workflows/release.yml` builds the release files on GitHub: `OSRS-Dashboard-Setup.exe` and
`OSRS-Dashboard-Mac.dmg`, with Google Drive built in from the repository secret
`GOOGLE_CLIENT_JSON` (the whole `google-client.json`). To release, set `version` in `src-tauri/tauri.conf.json`,
then push a tag `v<version>`. GitHub makes a **draft** release with the files; check it and press **Publish**.
**Run workflow** on the Actions page only builds them, as downloadable artifacts.

## Building

Prerequisites:

- **Windows:** [Rust](https://rustup.rs) and the Microsoft C++ Build Tools ("Desktop development with C++").
  WebView2 is included with Windows 10 and 11.
- **macOS:** [Rust](https://rustup.rs) and the Xcode command line tools (`xcode-select --install`).
- Both: `cargo install tauri-cli --version "^2" --locked`

From `app/src-tauri`:

```
cargo tauri build --bundles nsis       # Windows installer: target/release/bundle/nsis/
cargo tauri build --bundles app        # macOS app: target/release/bundle/macos/OSRS Dashboard.app
```

Tauri's own disk image step (`--bundles dmg`) can fail with `hdiutil: couldn't unmount "diskN" - Resource busy`,
because its script has Finder style the window while Finder keeps the image open. Make the disk image with `hdiutil`
instead. From `app/src-tauri/target/release/bundle`:

```
mkdir dmg-src && cp -R "macos/OSRS Dashboard.app" dmg-src/ && ln -s /Applications dmg-src/Applications
hdiutil create -volname "OSRS Dashboard" -srcfolder dmg-src -fs HFS+ -format UDZO -ov OSRS-Dashboard-Mac.dmg
```

The macOS build runs on Apple silicon only (M1 and newer).

Before compiling, `build.rs` copies the page, fonts, chart library, images and reference lists into
`app/bundle/dashboard/` from an allow-list. The build fails if it finds personal
data (history, bank, prices, settings, the builder's player name or user folder).

Builds are not code-signed. Windows SmartScreen and macOS Gatekeeper show a warning on first launch:

- **Windows:** **More info**, then **Run anyway**.
- **macOS 15 and later:** open the app once, select **Done**, then **System Settings → Privacy & Security → Open
  Anyway** next to "OSRS Dashboard". On macOS 14 and older: right-click the app, select **Open**, then **Open** again.

## Tests

```
cargo test                                                        # in app/src-tauri
python3 tools/sync-test.py app/src-tauri/target/release/osrs-dashboard synced
AUTO=1 python3 tools/sync-test.py app/src-tauri/target/release/osrs-dashboard synced   # through a folder, real Updates
```

`tools/sync-test.py` runs two "computers" on copies of your data folder (your real data is only read): each plays on
a different day, then they sync. It checks that both end up with the same history, the collection log counts each
drop once, no false "played without the plugin" entries appear, a second import changes nothing, and an Update
afterwards keeps the newer data. Use `unsynced` instead of `synced` for two RuneLites that don't share Loot Tracker
totals. `--root` and `--plugin` pick other folders to copy.
