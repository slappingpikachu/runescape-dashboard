# OSRS Dashboard desktop app

A standalone Windows and macOS build of the dashboard, made with [Tauri 2](https://tauri.app). It serves the same
`index.html`, `app.js` and `styles.css` as the PowerShell version, handles the page's requests in Rust
(`src-tauri/src/server.rs`) and reads and writes the same data files in the same formats. It opens no network
port.

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
when you update or import. All other hosts are blocked in `src-tauri/src/net.rs`. JSON export files are read from
`~/.runelite/plugin-data/osrsdatasync/`.

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
`app/bundle/dashboard/` using the same allow-list as `tools/make-release.ps1`. The build fails if it finds personal
data (history, bank, prices, settings, the builder's player name or user folder).

Builds are not code-signed. Windows SmartScreen and macOS Gatekeeper show a warning on first launch:

- **Windows:** **More info**, then **Run anyway**.
- **macOS:** right-click the app, select **Open**, then **Open** again.

## Tests

```
cargo test                                                                        # in app/src-tauri
powershell -ExecutionPolicy Bypass -File tools\test-plugin-files.ps1 -Impl app    # plugin file handling
powershell -ExecutionPolicy Bypass -File tools\parity-test.ps1 -Fresh -Wom        # app vs. PowerShell
```

`parity-test.ps1` runs both versions on copies of your data and compares every file they write. It covers every
page request, two refreshes, a first run on an empty install and the Wise Old Man import. The app's downloads are
recorded and replayed to the PowerShell version, so both see identical responses at the same fixed time.
