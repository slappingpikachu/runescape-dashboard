// Refresh (server.ps1 Invoke-Refresh), first-start setup and the Wise Old Man offer.
// A Refresh downloads the official hiscores (and the GE prices) at the same time, saves the snapshot to
// data\history.jsonl, merges older days into daily snapshots, then turns the plugin's files into the dashboard's data.

use crate::icons::Icons;
use crate::net::{Web, HISCORE_UA, UA};
use crate::util::*;
use chrono::{Local, TimeZone};
use regex::Regex;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

const COOLDOWN: u64 = 60; // minimum seconds between hiscore requests
const KEEP_ALL_DAYS: i64 = 14;

// Everything one Refresh needs: where the files are and the download / picture helpers
pub struct Ctx<'a> {
    pub data: PathBuf,
    pub plugin_dir: PathBuf,
    pub web: &'a Web,
    pub icons: &'a Icons,
}

impl Ctx<'_> {
    pub fn clog_dir(&self) -> PathBuf {
        self.data.join("clog")
    }
    pub fn plugin_data(&self) -> PathBuf {
        self.data.join("plugin")
    }
    pub fn loot_gap_file(&self) -> PathBuf {
        self.plugin_data().join("loot-gaps.jsonl")
    }
}

// ~/.runelite/plugin-data/osrsdatasync/<name> (tests: OSRS_PLUGIN_ROOT=<folder holding the player folders>)
static NOT_NAME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^a-z0-9_-]+").unwrap());
pub fn plugin_dir(player: &str) -> PathBuf {
    let name = trim(&player.replace('\u{a0}', " ")).to_lowercase();
    let name = NOT_NAME.replace_all(&name, "_").into_owned();
    let root = match std::env::var_os("OSRS_PLUGIN_ROOT") {
        Some(r) => PathBuf::from(r),
        None => home_dir().join(".runelite").join("plugin-data").join("osrsdatasync"),
    };
    root.join(name)
}

// The user's home folder (PowerShell's $HOME): USERPROFILE on Windows, HOME on Mac
pub fn home_dir() -> PathBuf {
    std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from).unwrap_or_default()
}

// ---- settings.json: {"player": "Name", "womAsked": true|false} ----
#[derive(Clone, Default)]
pub struct Settings {
    pub player: String,
    pub wom_asked: bool,
}

pub fn load_settings(root: &Path) -> Settings {
    let Some(v) = read_text(&root.join("settings.json")).and_then(|t| serde_json::from_str::<Value>(trim(&t)).ok()) else {
        return Settings::default();
    };
    let player = if opt_truthy(prop(&v, "player")) { trim(&ps_string(prop(&v, "player"))).to_string() } else { String::new() };
    Settings { player, wom_asked: opt_truthy(prop(&v, "womAsked")) }
}

// Written like PowerShell 5.1's ConvertTo-Json (not compressed)
pub fn save_settings(root: &Path, s: &Settings) {
    let text = format!(
        "{{\r\n    \"player\":  {},\r\n    \"womAsked\":  {}\r\n}}",
        if s.player.is_empty() { "null".into() } else { ps_str(&s.player) },
        s.wom_asked
    );
    if let Err(e) = write_text(&root.join("settings.json"), &text) {
        eprintln!("settings.json could not be saved: {e}");
    }
}

fn log(msg: &str) {
    eprintln!("[{}] {msg}", Local::now().format("%H:%M:%S"));
}

fn hiscore_url(player: &str) -> String {
    format!("https://secure.runescape.com/m=hiscore_oldschool/index_lite.json?player={}", escape_data(player))
}

fn no_quotes(s: &str) -> String {
    s.chars().filter(|c| *c != '\\' && *c != '"').collect()
}

// The Refresh. `last_fetch` is the time of the last hiscores request (the cooldown). Returns (status, error JSON);
// 200 = done (the route sends the history).
pub fn refresh(root: &Path, web: &Web, icons: &Icons, player: &str, last_fetch: &mut Option<Instant>) -> (u16, String) {
    if player.is_empty() {
        return (400, r#"{"error":"Set up your player name first."}"#.into());
    }
    if let Some(t) = last_fetch {
        let wait = COOLDOWN as f64 - t.elapsed().as_secs_f64();
        if wait > 0.0 {
            return (429, format!(r#"{{"error":"Please wait {}s before updating again."}}"#, wait.ceil() as i64));
        }
    }
    *last_fetch = Some(Instant::now());
    let started = Instant::now();
    let data = root.join("data");
    ensure_dir(&data);
    let ctx = Ctx { data: data.clone(), plugin_dir: plugin_dir(player), web, icons };

    // Hiscores + GE prices now + the GE prices on the days the periods start (only days not on disk yet), together
    let hs = hiscore_url(player);
    let past = crate::bank::past_urls(&ctx);
    let mut jobs: Vec<(String, &str)> = vec![(hs.clone(), HISCORE_UA), (crate::clog::PRICES_URL.to_string(), UA)];
    jobs.extend(past.iter().map(|u| (u.clone(), UA)));
    let got = web.fetch_all(&jobs);

    let h = &got[0];
    if h.status == 404 {
        *last_fetch = Instant::now().checked_sub(Duration::from_secs(COOLDOWN - 5)); // a mistyped name: retry after 5 s
        return (
            404,
            format!(
                r#"{{"error":"'{}' isn't on the OSRS hiscores. Check the spelling (accounts need some XP to be listed)."}}"#,
                no_quotes(player)
            ),
        );
    }
    let Some(body) = h.text().filter(|_| h.status == 200) else {
        return (502, r#"{"error":"Could not reach the OSRS hiscores. Try again later."}"#.into());
    };
    let snapshot = trim(&body.replace(['\r', '\n'], "")).to_string();
    let time = iso(now());
    let history = data.join("history.jsonl");
    if let Err(e) = append_text(&history, &format!("{{\"t\":\"{time}\",\"d\":{snapshot}}}\n")) {
        return (500, format!(r#"{{"error":{}}}"#, ps_str(&format!("Could not save the snapshot: {e}"))));
    }
    log(&format!("Saved hiscores snapshot (all sites answered in {} ms)", started.elapsed().as_millis()));
    if let Err(e) = compress_history(&data) {
        log(&format!("History merge failed: {e}"));
    }

    // Everything else comes from the OSRS Data Sync plugin's files on this PC. Failures never block the Refresh.
    let mut pre = HashMap::new();
    for (i, (url, _)) in jobs.iter().enumerate().skip(1) {
        if got[i].status == 200 {
            if let Some(t) = got[i].text() {
                pre.insert(url.clone(), t);
            }
        }
    }
    web.start_refresh(pre);
    let step = |name: &str, r: Res<String>| match r {
        Ok(m) => log(&m),
        Err(e) => log(&format!("{name} failed: {e}")),
    };
    step("Progress", crate::plugin::update_progress(&ctx));
    // Before the collection log: it counts log items among those drops too
    step("Drop log gaps", crate::plugin::update_loot_gaps(&ctx));
    step("Collection log", crate::plugin::update_clog(&ctx));
    step("Bank", crate::bank::update(&ctx));
    step("Plugin kills", crate::plugin::update_kills(&ctx, &time));
    web.end_refresh();
    log(&format!("Refresh done in {} ms", started.elapsed().as_millis()));
    (200, String::new())
}

// Daily snapshots: only the last 14 days keep every Refresh; older days keep just their last snapshot, plus the very
// first. Days are game days (00:00 UTC); lines from before 2026-10-19 (local) were merged by LOCAL days and keep that
// grouping. The first time, the full file is copied to history.before-daily-<date>.jsonl.
pub fn compress_history(data: &Path) -> Res<()> {
    let file = data.join("history.jsonl");
    let Some(text) = read_text(&file) else { return Ok(()) };
    let lines = split_lines(&text);
    let cutoff = today_utc() - chrono::Days::new(KEEP_ALL_DAYS as u64);
    let utc_days_from = Local.with_ymd_and_hms(2026, 10, 19, 0, 0, 0).earliest().map(|t| t.to_utc());
    let mut days = Vec::with_capacity(lines.len());
    for l in &lines {
        let end = l.get(6..).and_then(|r| r.find('"')).ok_or("A history line has no time")?;
        let t = parse_time_or_err(&l[6..6 + end])?;
        days.push(if utc_days_from.map(|f| t < f).unwrap_or(false) {
            format!("L{}", t.with_timezone(&Local).format("%Y-%m-%d"))
        } else {
            format!("U{}", t.format("%Y-%m-%d"))
        });
    }
    let cutoff_key = format!("U{}", cutoff.format("%Y-%m-%d"));
    let n = lines.len();
    let keep: Vec<&str> = (0..n)
        .filter(|&i| i == 0 || (days[i].starts_with('U') && days[i] >= cutoff_key) || i == n - 1 || days[i + 1] != days[i])
        .map(|i| lines[i])
        .collect();
    if keep.len() == n {
        return Ok(());
    }
    let has_backup = std::fs::read_dir(data)
        .map(|rd| {
            rd.flatten().any(|e| {
                let n = e.file_name().to_string_lossy().to_lowercase();
                n.starts_with("history.before-daily-") && n.ends_with(".jsonl")
            })
        })
        .unwrap_or(false);
    if !has_backup {
        let name = format!("history.before-daily-{}.jsonl", now().with_timezone(&Local).format("%Y%m%d"));
        std::fs::copy(&file, data.join(name)).err_text()?;
    }
    let tmp = data.join("history.jsonl.tmp");
    write_text(&tmp, &format!("{}\n", keep.join("\n"))).err_text()?;
    std::fs::rename(&tmp, &file).err_text()?;
    log(&format!("History: merged older days into daily snapshots ({n} -> {} snapshots)", keep.len()));
    Ok(())
}

// POST /api/setup {"player": "Name"}: checked on the hiscores (that request is the first Refresh), then saved.
// Only while no name is set, so one install never mixes two accounts' history.
pub fn setup(
    root: &Path,
    web: &Web,
    icons: &Icons,
    settings: &std::sync::Mutex<Settings>,
    last_fetch: &mut Option<Instant>,
    body: &[u8],
) -> (u16, String) {
    let name = serde_json::from_slice::<Value>(body)
        .ok()
        .map(|v| trim(&ps_string(prop(&v, "player"))).to_string())
        .unwrap_or_default();
    let current = settings.lock().unwrap().player.clone();
    if !current.is_empty() {
        return (
            409,
            format!(r#"{{"error":"This dashboard is already set up for {}. Edit settings.json to change it."}}"#, no_quotes(&current)),
        );
    }
    static OK_NAME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9 _-]{1,12}$").unwrap());
    if !OK_NAME.is_match(&name) {
        return (400, r#"{"error":"OSRS names are 1-12 letters, numbers, spaces, - or _."}"#.into());
    }
    let r = refresh(root, web, icons, &name, last_fetch);
    if r.0 == 200 {
        let mut s = settings.lock().unwrap();
        s.player = name;
        s.wom_asked = false;
        save_settings(root, &s);
        log(&format!("Set up for {} (saved in settings.json)", s.player));
    } else if r.0 == 502 {
        *last_fetch = Instant::now().checked_sub(Duration::from_secs(COOLDOWN - 5));
    }
    r
}

// POST /api/wom: {"import": true} imports older history once, {"import": false} = no thanks. Never offered again.
pub fn wom(root: &Path, web: &Web, settings: &std::sync::Mutex<Settings>, body: &[u8]) -> (u16, String) {
    let want = serde_json::from_slice::<Value>(body).ok().map(|v| opt_truthy(prop(&v, "import"))).unwrap_or(false);
    let player = settings.lock().unwrap().player.clone();
    let answered = || {
        let mut s = settings.lock().unwrap();
        s.wom_asked = true;
        save_settings(root, &s);
    };
    if player.is_empty() {
        return (400, r#"{"error":"Set up your player name first."}"#.into());
    }
    if !want {
        answered();
        return (200, r#"{"message":null}"#.into());
    }
    match crate::wom::import(web, &player, &root.join("data").join("history.jsonl")) {
        Ok(r) => {
            answered();
            let day = |s: &str| parse_time(s).map(|t| t.with_timezone(&Local).format("%b %-d, %Y").to_string()).unwrap_or_default();
            let msg = format!("Imported {} snapshots from Wise Old Man ({} to {}).", r.kept, day(&r.from), day(&r.to));
            log(&msg);
            (200, format!(r#"{{"message":{}}}"#, ps_str(&msg)))
        }
        Err(msg) => {
            // Nothing on Wise Old Man for this name: answered, don't offer again. Busy / offline: offer again later.
            let l = msg.to_lowercase();
            if l.contains("doesn't track") || l.contains("no snapshots") || l.contains("already imported") {
                answered();
            }
            (422, format!(r#"{{"error":{}}}"#, ps_str(&msg)))
        }
    }
}
