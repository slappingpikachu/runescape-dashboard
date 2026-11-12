// Export / Import and automatic sync between your own devices (what is merged and why: below).
//
//   POST /api/export  one file in Downloads with this device's history (for Import on the other device)
//   POST /api/import  body = such a file from another device, merged into this device's data
//   GET  /api/sync    {"device","exported","imported"} for the page
//
// What is merged and why (moved here from sync.ps1 when the PowerShell version was retired):
// Export / Import between your own devices (e.g. a Windows PC and a Mac), so both dashboards hold the same history.
// Export writes one file to your Downloads folder; move it to the other device any way you like (AirDrop, USB stick,
// email to yourself) and Import it there. Nothing goes over the network. Dot-sourced by server.ps1 after plugin.ps1.
//
// Import MERGES: every history keeps the snapshots of both devices (the same snapshot twice = once), sorted by time.
//   history.jsonl, bank\history.jsonl, bank\prices-saves.jsonl, plugin\kills-history.jsonl   one line per time "t"
//   progress\history.jsonl   + latest.json when the other device's newest progress is newer
//   clog\history.jsonl       from the other device's first line on, each line holds every item either device had by
//                            then (highest count, earliest date); the last line keeps THIS device's lootT/gapN markers
//   bank\history.jsonl       a line whose bank was seen before an earlier line's bank (the device hadn't opened the
//                            bank since) gets that newer bank, so the value graph doesn't dip back to an old bank
//   loot                     the other device's loot.jsonl -> data\plugin\loot-other.jsonl (the plugin's own file is
//                            never written). Drop log gaps (loot-gaps.jsonl) stay per device: with RuneLite's synced
//                            Loot Tracker, kills made on the other device look like "played without the plugin" here,
//                            so a gap is reduced by the other device's real drops in its window (Get-SyncDrops).
//                            The other device's gaps from before this device's drop log began -> gaps-other.jsonl.
// Settings (player name, Wise Old Man answer), prices and pictures stay per device.
//
// The file: line 1 {"osrsDashboardSync":1,"player","device":{"id","name"},"exported","seen":{..}}, then for each part
// a line {"section":"<name>"} followed by that file's lines as they are (every part is JSON lines; no line starts
// with {"section").
//
// data\sync\state.json  {"id","name","seen":{"progress","killcounts","containers","bankAt"},"exported","imported"}
//   seen = the newest plugin files ("updated" times, bank time) of any device merged in. A Refresh skips a plugin file
//   older than that (RuneLite hasn't run on this device since), so old quests / bank / kill totals from here never
//   become the newest snapshot. Once RuneLite runs here again, its files are newer and count as usual.
// data\sync\backup-<time>\  the files as they were before an import (the newest 3 are kept)

use crate::refresh::{home_dir, plugin_dir};
use crate::util::*;
use chrono::{DateTime, Local, NaiveDateTime, Utc};
use indexmap::IndexMap;
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

const VERSION: i64 = 1;
// Part name in the file -> path under data\
const PARTS: &[(&str, &[&str])] = &[
    ("history", &["history.jsonl"]),
    ("bank", &["bank", "history.jsonl"]),
    ("bankPrices", &["bank", "prices-saves.jsonl"]),
    ("progress", &["progress", "history.jsonl"]),
    ("clog", &["clog", "history.jsonl"]),
    ("kills", &["plugin", "kills-history.jsonl"]),
];

fn part_file(data: &Path, part: &str) -> PathBuf {
    let mut p = data.to_path_buf();
    for (name, segs) in PARTS {
        if *name == part {
            for s in *segs {
                p = p.join(s);
            }
        }
    }
    p
}
fn sync_dir(data: &Path) -> PathBuf {
    data.join("sync")
}
fn state_file(data: &Path) -> PathBuf {
    sync_dir(data).join("state.json")
}
pub fn loot_other_file(data: &Path) -> PathBuf {
    data.join("plugin").join("loot-other.jsonl")
}
pub fn gaps_other_file(data: &Path) -> PathBuf {
    data.join("plugin").join("gaps-other.jsonl")
}
fn gap_file(data: &Path) -> PathBuf {
    data.join("plugin").join("loot-gaps.jsonl")
}

// ---- small helpers ----

static LINE_T: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"^\{"t":"([^"]*)""#).unwrap());
static TIMESTAMP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""timestamp":"([^"]*)""#).unwrap());
static UPDATED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""updated":"([^"]*)""#).unwrap());

fn time_of(s: Option<&str>) -> DateTime<Utc> {
    s.and_then(parse_time).unwrap_or(DateTime::<Utc>::MIN_UTC)
}
fn line_t(l: &str) -> Option<&str> {
    LINE_T.captures(l).map(|c| c.get(1).unwrap().as_str())
}
fn by_t(l: &str) -> DateTime<Utc> {
    time_of(line_t(l))
}
// Non-blank lines of a file, trimmed
fn lines_of(path: &Path) -> Vec<String> {
    read_lines(path).iter().map(|l| trim(l).to_string()).filter(|l| !l.is_empty()).collect()
}
fn write_lines(path: &Path, lines: &[String]) -> Res<()> {
    if let Some(dir) = path.parent() {
        ensure_dir(dir);
    }
    let tmp = path.with_file_name(format!("{}.tmp", path.file_name().unwrap().to_string_lossy()));
    let text = if lines.is_empty() { String::new() } else { format!("{}\n", lines.join("\n")) };
    write_text(&tmp, &text).err_text()?;
    std::fs::rename(&tmp, path).err_text()
}
// Lines sorted by time, oldest first; the same time keeps the order (stable)
fn sort_lines(lines: Vec<String>, time: impl Fn(&str) -> DateTime<Utc>) -> Vec<String> {
    let mut keyed: Vec<(DateTime<Utc>, String)> = lines.into_iter().map(|l| (time(&l), l)).collect();
    keyed.sort_by_key(|(t, _)| *t);
    keyed.into_iter().map(|(_, l)| l).collect()
}
// The "updated" time in a plugin file's text ("" when there is none)
pub fn updated_in(text: &str) -> String {
    UPDATED.captures(text).map(|c| c[1].to_string()).unwrap_or_default()
}

// ---- this device: data\sync\state.json ----

#[derive(Clone, Default)]
struct Seen {
    progress: Option<String>,
    killcounts: Option<String>,
    containers: Option<String>,
    bank_at: i64,
}
impl Seen {
    fn get(&self, kind: &str) -> Option<&String> {
        match kind {
            "progress" => self.progress.as_ref(),
            "killcounts" => self.killcounts.as_ref(),
            "containers" => self.containers.as_ref(),
            _ => None,
        }
    }
    fn set(&mut self, kind: &str, v: Option<String>) {
        match kind {
            "progress" => self.progress = v,
            "killcounts" => self.killcounts = v,
            "containers" => self.containers = v,
            _ => {}
        }
    }
    fn json(&self) -> Value {
        let s = |v: &Option<String>| v.clone().map(Value::String).unwrap_or(Value::Null);
        json!({"progress": s(&self.progress), "killcounts": s(&self.killcounts), "containers": s(&self.containers), "bankAt": self.bank_at})
    }
}
struct State {
    id: String,
    name: String,
    seen: Seen,
    exported: Option<String>,
    imported: Option<Value>,
    // Automatic sync through a shared folder (see "Automatic sync" below)
    folder: Option<String>,               // the folder picked by hand; None = Google Drive, found by itself
    auto_seen: IndexMap<String, String>,  // device id -> "exported" of its newest file merged in
    auto_exported: Option<String>,
    auto_error: Option<String>,
}

fn opt_str(v: Option<&Value>) -> Option<String> {
    if opt_truthy(v) {
        Some(ps_string(v))
    } else {
        None
    }
}

fn load_state(data: &Path) -> State {
    let s = read_text(&state_file(data)).and_then(|t| serde_json::from_str::<Value>(trim(&t)).ok()).unwrap_or(Value::Null);
    let seen = prop(&s, "seen").cloned().unwrap_or(Value::Null);
    let imported = prop(&s, "imported").filter(|v| truthy(v)).map(|i| {
        json!({"from": ps_string(prop(i, "from")), "name": ps_string(prop(i, "name")), "exported": ps_string(prop(i, "exported")), "t": ps_string(prop(i, "t"))})
    });
    let mut st = State {
        id: opt_str(prop(&s, "id")).unwrap_or_default(),
        name: opt_str(prop(&s, "name")).unwrap_or_default(),
        seen: Seen {
            progress: opt_str(prop(&seen, "progress")),
            killcounts: opt_str(prop(&seen, "killcounts")),
            containers: opt_str(prop(&seen, "containers")),
            bank_at: ps_long(prop(&seen, "bankAt")),
        },
        exported: opt_str(prop(&s, "exported")),
        imported,
        folder: opt_str(prop(&s, "folder")),
        auto_seen: props(prop(&s, "autoSeen")).into_iter().map(|(k, v)| (k, ps_string(Some(&v)))).collect(),
        auto_exported: opt_str(prop(&s, "autoExported")),
        auto_error: opt_str(prop(&s, "autoError")),
    };
    if st.id.is_empty() {
        st.id = random_id();
        st.name = device_name();
        let _ = save_state(data, &st);
    }
    st
}

fn save_state(data: &Path, st: &State) -> Res<()> {
    ensure_dir(&sync_dir(data));
    let v = json!({
        "id": st.id, "name": st.name, "seen": st.seen.json(),
        "exported": st.exported.clone().map(Value::String).unwrap_or(Value::Null),
        "imported": st.imported.clone().unwrap_or(Value::Null),
        "folder": st.folder.clone().map(Value::String).unwrap_or(Value::Null),
        "autoSeen": Value::Object(st.auto_seen.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect()),
        "autoExported": st.auto_exported.clone().map(Value::String).unwrap_or(Value::Null),
        "autoError": st.auto_error.clone().map(Value::String).unwrap_or(Value::Null)
    });
    write_text(&state_file(data), &ps_json(&v)).err_text()
}

fn random_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
    h.write_u32(std::process::id());
    format!("{:016x}", h.finish())
}

// The computer's name, like .NET's Environment.MachineName
fn device_name() -> String {
    if let Ok(n) = std::env::var("COMPUTERNAME") {
        if !n.is_empty() {
            return n;
        }
    }
    let n = std::process::Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .map(|o| trim(&String::from_utf8_lossy(&o.stdout)).to_string())
        .unwrap_or_default();
    if n.is_empty() {
        "This device".into()
    } else {
        n
    }
}

// The newer of two ISO times (either may be missing)
fn newer(a: Option<String>, b: Option<String>) -> Option<String> {
    match (a, b) {
        (None, b) => b,
        (a, None) => a,
        (Some(a), Some(b)) => {
            if time_of(Some(&b)) > time_of(Some(&a)) {
                Some(b)
            } else {
                Some(a)
            }
        }
    }
}

// For the Refresh steps: is this plugin file ("progress" / "killcounts" / "containers", its "updated" time) older than
// one merged in from another device? Then it is skipped (sync.ps1).
pub fn is_stale(data: &Path, kind: &str, updated: &str) -> bool {
    if !state_file(data).exists() {
        return false;
    }
    let st = load_state(data);
    let Some(seen) = st.seen.get(kind) else { return false };
    let Some(u) = parse_time(updated) else { return false };
    u < time_of(Some(seen))
}
pub fn seen_bank_at(data: &Path) -> i64 {
    if state_file(data).exists() {
        load_state(data).seen.bank_at
    } else {
        0
    }
}

// The newest plugin files this device knows of: its own (now) or merged in earlier
fn seen_now(st: &State, plugin: &Path) -> Seen {
    let mut seen = st.seen.clone();
    for k in ["progress", "killcounts", "containers"] {
        let Some(o) = read_text(&plugin.join(format!("{k}.json"))).and_then(|t| serde_json::from_str::<Value>(trim(&t)).ok()) else {
            continue;
        };
        let cur = seen.get(k).cloned();
        seen.set(k, newer(cur, Some(ps_string(prop(&o, "updated"))).filter(|s| !s.is_empty())));
        if k == "containers" && ps_long(prop(&o, "bankAt")) > seen.bank_at {
            seen.bank_at = ps_long(prop(&o, "bankAt"));
        }
    }
    seen
}

pub fn status(data: &Path, player: &str) -> String {
    let st = load_state(data);
    let s = |v: Option<String>| v.map(Value::String).unwrap_or(Value::Null);
    let folder = auto_folder(data, &st);
    // The other devices' files (folder and/or Google Drive): name + when exported
    let mut list_err = None;
    let others: Vec<Value> = other_files(data, player, &st, &mut list_err)
        .into_iter()
        .map(|o| json!({"name": o.name, "exported": o.exported, "merged": st.auto_seen.get(&o.id).map(|t| time_of(Some(t)) >= time_of(Some(&o.exported))).unwrap_or(false)}))
        .collect();
    ps_json(&json!({
        "device": st.name,
        "exported": s(st.exported),
        "imported": st.imported.unwrap_or(Value::Null),
        "folder": s(folder.map(|f| f.display().to_string())),
        "folderSet": s(st.folder),
        "autoExported": s(st.auto_exported),
        "autoError": s(list_err.or(st.auto_error)),
        "others": others,
        "google": crate::gdrive::status(data)
    }))
}

fn error(status: u16, msg: &str) -> (u16, String) {
    (status, format!(r#"{{"error":{}}}"#, ps_str(msg)))
}

// ---- Export ----

// The export file's text, and how many lines each part has
fn export_text(data: &Path, player: &str, st: &State, now_s: &str) -> (String, HashMap<&'static str, usize>) {
    let plugin = plugin_dir(player);
    let head = json!({
        "osrsDashboardSync": VERSION, "player": player, "device": {"id": st.id, "name": st.name},
        "exported": now_s, "seen": seen_now(st, &plugin).json()
    });
    let mut out = String::new();
    out.push_str(&ps_json(&head));
    out.push('\n');
    let mut counts: HashMap<&str, usize> = HashMap::new();
    let mut add = |name: &'static str, file: &Path| {
        out.push_str(&format!("{{\"section\":\"{name}\"}}\n"));
        let mut n = 0;
        for l in lines_of(file) {
            if !l.starts_with(r#"{"section""#) {
                out.push_str(&l);
                out.push('\n');
                n += 1;
            }
        }
        counts.insert(name, n);
    };
    for (part, _) in PARTS {
        add(part, &part_file(data, part));
    }
    add("loot", &plugin.join("loot.jsonl")); // this device's own drops only (not loot-other)
    add("gaps", &gap_file(data));
    // RuneLite's current files (Kills & loot, GE offers, storage...): this device's own or, when newer, the ones the
    // other device sent. One line each: {"file":"killcounts.json","data":<the file>}
    out.push_str("{\"section\":\"pluginFiles\"}\n");
    for f in PLUGIN_FILES {
        if let Some((text, _)) = newest_plugin_file(data, &plugin, f) {
            out.push_str(&format!("{{\"file\":\"{f}\",\"data\":{text}}}\n"));
        }
    }
    // Last line: the file is whole (an automatic import skips a file the cloud drive hasn't finished copying)
    out.push_str(END_LINE);
    out.push('\n');
    (out, counts)
}

const END_LINE: &str = r#"{"section":"end"}"#;

// ---- RuneLite's current files from the other device ----
// The page shows some sections straight from the plugin's files (Kills & loot from killcounts.json, GE offers and
// storage from containers.json, ...). A device where RuneLite doesn't run would show old ones, so they travel in
// the sync file too; data/plugin/other/<file> keeps the other device's copy, and the page gets whichever of the two
// has the newer "updated" time.
pub const PLUGIN_FILES: &[&str] = &["progress.json", "killcounts.json", "clog.json", "containers.json"];

pub fn other_plugin_dir(data: &Path) -> PathBuf {
    data.join("plugin").join("other")
}

// A whole JSON object file's text (one line), or None (missing, empty, cut off)
fn whole_json(path: &Path) -> Option<String> {
    let t = read_text(path)?;
    let t = trim(&t).replace(['\r', '\n'], "");
    (t.starts_with('{') && t.ends_with('}')).then_some(t)
}

// The newer of this device's plugin file and the other device's copy: (text, from the other device)
pub fn newest_plugin_file(data: &Path, plugin: &Path, name: &str) -> Option<(String, bool)> {
    let own = whole_json(&plugin.join(name));
    let other = whole_json(&other_plugin_dir(data).join(name));
    match (own, other) {
        (Some(a), Some(b)) => {
            if time_of(Some(&updated_in(&b))) > time_of(Some(&updated_in(&a))) {
                Some((b, true))
            } else {
                Some((a, false))
            }
        }
        (Some(a), None) => Some((a, false)),
        (None, Some(b)) => Some((b, true)),
        (None, None) => None,
    }
}

pub fn export(data: &Path, player: &str) -> (u16, String) {
    if player.is_empty() {
        return error(400, "Set up your player name first.");
    }
    let mut st = load_state(data);
    let now_s = iso(now());
    let (out, counts) = export_text(data, player, &st, &now_s);
    let home = home_dir();
    let mut dir = std::env::var_os("OSRS_SYNC_EXPORT_DIR").map(PathBuf::from).unwrap_or_else(|| home.join("Downloads"));
    if !dir.is_dir() {
        dir = home;
    }
    static NOT_DEV: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^A-Za-z0-9 _-]").unwrap());
    let dev = trim(&NOT_DEV.replace_all(&st.name, "")).to_string();
    let file = dir.join(format!(
        "OSRS Dashboard sync - {player} - {dev} - {}.osrssync",
        now().with_timezone(&Local).format("%Y-%m-%d %H%M")
    ));
    if let Err(e) = write_text(&file, &out) {
        return error(500, &format!("Could not save the file: {e}"));
    }
    st.exported = Some(now_s);
    let _ = save_state(data, &st);
    let path = file.display().to_string();
    eprintln!("Exported for another device: {path}");
    let c = |k: &str| counts.get(k).copied().unwrap_or(0);
    let msg = format!("Saved to {path} ({} hiscores snapshots, {} bank saves, {} drops).", c("history"), c("bank"), c("loot"));
    (200, ps_json(&json!({"message": msg, "path": path})))
}

// ---- Import ----

struct Merged {
    lines: Vec<String>,
    added: usize,
    from: Option<usize>, // the first line from the other device in `lines`
}

fn merge_by_t(own: Vec<String>, other: &[String]) -> Merged {
    let mut keys: HashSet<String> = own.iter().map(|l| line_t(l).map(str::to_string).unwrap_or_else(|| l.clone())).collect();
    let mut all = own.clone();
    let mut new: HashSet<String> = HashSet::new();
    for l in other {
        let Some(k) = line_t(l) else { continue };
        if keys.insert(k.to_string()) {
            all.push(l.clone());
            new.insert(l.clone());
        }
    }
    if new.is_empty() {
        return Merged { lines: own, added: 0, from: None };
    }
    let sorted = sort_lines(all, by_t);
    let from = sorted.iter().position(|l| new.contains(l));
    Merged { lines: sorted, added: new.len(), from }
}

static SAVED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""saved":"((?:[^"\\]|\\.)*)""#).unwrap());
static BANK_ITEMS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""items":\[(?:\[-?\d+,-?\d+\],?)*\]"#).unwrap());

// When a bank line's bank was last seen open ("HH:mm:ss, d MMM yyyy", local time; "before ..." when not exact)
fn bank_seen(line: &str) -> Option<NaiveDateTime> {
    let s = SAVED.captures(line)?.get(1)?.as_str();
    let s = s.strip_prefix("before ").unwrap_or(s);
    NaiveDateTime::parse_from_str(s, "%H:%M:%S, %d %b %Y").ok()
}

// From the first merged line on, a line whose bank is older than an earlier line's gets that bank
fn repair_bank(m: &mut Merged) -> usize {
    let Some(from) = m.from else { return 0 };
    let mut best: Option<(NaiveDateTime, String, String)> = None; // seen, items, saved
    let mut fixed = 0;
    for i in 0..m.lines.len() {
        let Some(seen) = bank_seen(&m.lines[i]) else { continue };
        if let Some((bs, items, saved)) = &best {
            if seen < *bs && i >= from {
                let line = m.lines[i].clone();
                if let Some(x) = BANK_ITEMS.find(&line) {
                    let l = format!("{}{}{}", &line[..x.start()], items, &line[x.end()..]);
                    m.lines[i] = SAVED.replace(&l, regex::NoExpand(saved)).into_owned();
                    fixed += 1;
                }
                continue;
            }
        }
        if best.as_ref().map(|(bs, _, _)| seen >= *bs).unwrap_or(true) {
            let items = BANK_ITEMS.find(&m.lines[i]).map(|x| x.as_str().to_string()).unwrap_or_default();
            let saved = SAVED.find(&m.lines[i]).map(|x| x.as_str().to_string()).unwrap_or_default();
            best = if items.is_empty() { None } else { Some((seen, items, saved)) };
        }
    }
    fixed
}

static CLOG_HEAD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"^(.*?)"items":\{.*\}\}$"#).unwrap());
static TOTAL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""total":\d+"#).unwrap());
static AVAILABLE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""available":\d+"#).unwrap());
static LOOT_T: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""lootT":(null|"[^"]*")"#).unwrap());
static GAP_N: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""gapN":(null|-?\d+)"#).unwrap());

// Collection log lines from the first merged line on: every item either device had by then (highest count, earliest
// date); the last line gets this device's markers
fn repair_clog(m: &mut Merged, own: &[String]) {
    let Some(from) = m.from else { return };
    let mut run: IndexMap<String, (i64, String)> = IndexMap::new();
    let mut avail = 0i64;
    for i in 0..m.lines.len() {
        let Ok(o) = serde_json::from_str::<Value>(&m.lines[i]) else { continue };
        let mut mine: IndexMap<String, (i64, String)> = IndexMap::new();
        for (id, v) in props(prop(&o, "items")) {
            mine.insert(id, (ps_long(v.get(0)), ps_string(v.get(1))));
        }
        for (id, (c, d)) in &mine {
            match run.get_mut(id) {
                Some(was) => {
                    was.0 = was.0.max(*c);
                    if !d.is_empty() && (was.1.is_empty() || d.as_str() < was.1.as_str()) {
                        was.1 = d.clone();
                    }
                }
                None => {
                    run.insert(id.clone(), (*c, d.clone()));
                }
            }
        }
        avail = avail.max(ps_long(prop(&o, "available")));
        if i < from {
            continue;
        }
        let same = run.len() == mine.len() && run.iter().all(|(id, v)| mine.get(id) == Some(v));
        if same {
            continue;
        }
        let Some(c) = CLOG_HEAD.captures(&m.lines[i]) else { continue };
        let head = c[1].to_string();
        let head = TOTAL.replace_all(&head, format!("\"total\":{}", run.len()).as_str()).into_owned();
        let head = AVAILABLE.replace_all(&head, format!("\"available\":{avail}").as_str()).into_owned();
        let items: Vec<String> = run.iter().map(|(id, (c, d))| format!("\"{id}\":[{c},{}]", ps_str(d))).collect();
        m.lines[i] = format!("{head}\"items\":{{{}}}}}", items.join(","));
    }
    let last = m.lines.len() - 1;
    let own_last = own.last();
    if own_last.map(|l| *l == m.lines[last]).unwrap_or(false) {
        return;
    }
    let loot_t = own_last.and_then(|l| LOOT_T.captures(l)).map(|c| c[1].to_string()).unwrap_or_else(|| "null".into());
    let gap_n = own_last.and_then(|l| GAP_N.captures(l)).map(|c| c[1].to_string()).unwrap_or_else(|| "0".into());
    let l = LOOT_T.replace_all(&m.lines[last], regex::NoExpand(&format!("\"lootT\":{loot_t}"))).into_owned();
    m.lines[last] = GAP_N.replace_all(&l, regex::NoExpand(&format!("\"gapN\":{gap_n}"))).into_owned();
}

fn norm_player(n: &str) -> String {
    static NOT_NAME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^a-z0-9_-]+").unwrap());
    let n = trim(&n.replace('\u{a0}', " ")).to_lowercase();
    NOT_NAME.replace_all(&n, "_").into_owned()
}

fn copy_tree_into(src: &Path, data: &Path, backup: &Path) {
    let Ok(rel) = src.strip_prefix(data) else { return };
    let dst = backup.join(rel);
    if let Some(p) = dst.parent() {
        ensure_dir(p);
    }
    let _ = std::fs::copy(src, dst);
}

pub fn import(data: &Path, player: &str, body: &[u8]) -> (u16, String) {
    if player.is_empty() {
        return error(400, "Set up your player name first.");
    }
    let text = String::from_utf8_lossy(body);
    let text = text.strip_prefix('\u{feff}').unwrap_or(&text);
    let lines = split_lines(text);
    let head = lines.first().and_then(|l| serde_json::from_str::<Value>(l).ok()).unwrap_or(Value::Null);
    if ps_long(prop(&head, "osrsDashboardSync")) != VERSION {
        return error(400, "This isn't an OSRS Dashboard sync file (made with Export on another device).");
    }
    let file_player = ps_string(prop(&head, "player"));
    if norm_player(&file_player) != norm_player(player) {
        return error(409, &format!("This file is for {file_player}, but this dashboard is set up for {player}."));
    }
    let mut st = load_state(data);
    let device = prop(&head, "device").cloned().unwrap_or(Value::Null);
    if ps_string(prop(&device, "id")) == st.id {
        return error(409, "This file was exported on this device. Import it on your other device.");
    }
    static SECTION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"^\{"section":"([A-Za-z]+)"\}$"#).unwrap());
    let mut parts: HashMap<String, Vec<String>> = HashMap::new();
    let mut cur: Option<String> = None;
    for l in lines.iter().skip(1) {
        let l = trim(l);
        if l.is_empty() {
            continue;
        }
        if let Some(c) = SECTION.captures(l) {
            cur = Some(c[1].to_string());
            parts.insert(c[1].to_string(), Vec::new());
            continue;
        }
        if let Some(c) = &cur {
            if l.starts_with('{') && l.ends_with('}') {
                parts.get_mut(c).unwrap().push(l.to_string());
            }
        }
    }
    let empty = Vec::new();
    let get = |n: &str| parts.get(n).unwrap_or(&empty);

    // The files as they are now, in case something needs undoing (the newest 3 backups are kept)
    let backup = sync_dir(data).join(format!("backup-{}", Local::now().format("%Y%m%d-%H%M%S")));
    ensure_dir(&backup);
    let mut targets: Vec<PathBuf> = PARTS.iter().map(|(p, _)| part_file(data, p)).collect();
    targets.extend([data.join("progress").join("latest.json"), loot_other_file(data), gaps_other_file(data)]);
    for f in &targets {
        if f.exists() {
            copy_tree_into(f, data, &backup);
        }
    }
    if let Ok(rd) = std::fs::read_dir(sync_dir(data)) {
        let mut b: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.is_dir() && p.file_name().map(|n| n.to_string_lossy().starts_with("backup-")).unwrap_or(false)).collect();
        b.sort_by(|x, y| y.file_name().cmp(&x.file_name()));
        for old in b.into_iter().skip(3) {
            let _ = std::fs::remove_dir_all(old);
        }
    }

    let mut added: IndexMap<&str, usize> = IndexMap::new();
    let save = |file: &Path, lines: &[String]| -> Result<(), (u16, String)> {
        write_lines(file, lines).map_err(|e| error(500, &format!("Import failed: {e}")))
    };
    // Snapshots by time
    for part in ["history", "bank", "bankPrices"] {
        let file = part_file(data, part);
        let mut m = merge_by_t(lines_of(&file), get(part));
        added.insert(part, m.added);
        if part == "bank" {
            let fixed = repair_bank(&mut m);
            added.insert("bankFixed", fixed);
        }
        if m.added > 0 {
            if let Err(e) = save(&file, &m.lines) {
                return e;
            }
        }
    }
    // Kill totals: by time, then a line equal to the one before it is dropped
    let file = part_file(data, "kills");
    let m = merge_by_t(lines_of(&file), get("kills"));
    added.insert("kills", m.added);
    if m.added > 0 {
        static KILL_HEAD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"^\{"t":"[^"]*","#).unwrap());
        let mut out = Vec::new();
        let mut prev: Option<String> = None;
        for l in m.lines {
            let k = KILL_HEAD.replace(&l, "").into_owned();
            if prev.as_deref() != Some(k.as_str()) {
                out.push(l);
            }
            prev = Some(k);
        }
        if let Err(e) = save(&file, &out) {
            return e;
        }
    }
    // Collection log
    let file = part_file(data, "clog");
    let own = lines_of(&file);
    let mut m = merge_by_t(own.clone(), get("clog"));
    added.insert("clog", m.added);
    if m.added > 0 {
        repair_clog(&mut m, &own);
        if let Err(e) = save(&file, &m.lines) {
            return e;
        }
    }
    // Quests / diaries / combat achievements: whole states, dated by the plugin's "timestamp"
    let file = part_file(data, "progress");
    let own = lines_of(&file);
    let mut have: HashSet<String> = own.iter().cloned().collect();
    let mut all = own;
    let mut n = 0;
    for l in get("progress") {
        if have.insert(l.clone()) {
            all.push(l.clone());
            n += 1;
        }
    }
    added.insert("progress", n);
    if n > 0 {
        let ts = |l: &str| time_of(TIMESTAMP.captures(l).map(|c| c.get(1).unwrap().as_str()));
        let sorted = sort_lines(all, ts);
        if let Err(e) = save(&file, &sorted) {
            return e;
        }
        let latest = data.join("progress").join("latest.json");
        let newest = sorted.last().unwrap();
        let cur = read_text(&latest).unwrap_or_default();
        if ts(newest) > ts(&cur) {
            let _ = write_text(&latest, newest);
        }
    }
    // Drops: the other device's own drop log, next to this device's (never written into the plugin's file)
    let own_loot = lines_of(&plugin_dir(player).join("loot.jsonl"));
    let own_set: HashSet<&String> = own_loot.iter().collect();
    let mut lo = lines_of(&loot_other_file(data));
    let mut lo_set: HashSet<String> = lo.iter().cloned().collect();
    let mut n = 0;
    for l in get("loot") {
        if l.starts_with(r#"{"t":""#) && !own_set.contains(l) && lo_set.insert(l.clone()) {
            lo.push(l.clone());
            n += 1;
        }
    }
    added.insert("loot", n);
    if n > 0 {
        if let Err(e) = save(&loot_other_file(data), &sort_lines(lo, by_t)) {
            return e;
        }
    }
    // The other device's gaps from before this device's drop log began (later ones this device finds itself)
    let since = own_loot.iter().map(|l| by_t(l)).filter(|t| *t != DateTime::<Utc>::MIN_UTC).min().unwrap_or(DateTime::<Utc>::MAX_UTC);
    let mut go = lines_of(&gaps_other_file(data));
    let mut go_set: HashSet<String> = go.iter().cloned().collect();
    let mut n = 0;
    for l in get("gaps") {
        if l.starts_with(r#"{"t":""#) && by_t(l) <= since && go_set.insert(l.clone()) {
            go.push(l.clone());
            n += 1;
        }
    }
    added.insert("gaps", n);
    if n > 0 {
        if let Err(e) = save(&gaps_other_file(data), &sort_lines(go, by_t)) {
            return e;
        }
    }

    // RuneLite's current files from the other device, each kept when newer than the copy already here
    let mut n = 0;
    ensure_dir(&other_plugin_dir(data));
    for l in get("pluginFiles") {
        static FILE_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"^\{"file":"([a-z]+\.json)","data":(\{.*\})\}$"#).unwrap());
        let Some(c) = FILE_LINE.captures(l) else { continue };
        let (name, text) = (c[1].to_string(), c[2].to_string());
        if !PLUGIN_FILES.contains(&name.as_str()) || serde_json::from_str::<Value>(&text).is_err() {
            continue;
        }
        let dst = other_plugin_dir(data).join(&name);
        let cur = whole_json(&dst).map(|t| updated_in(&t)).unwrap_or_default();
        if time_of(Some(&updated_in(&text))) > time_of(Some(&cur)) {
            if let Err(e) = save(&dst, &[text]) {
                return e;
            }
            n += 1;
        }
    }
    added.insert("pluginFiles", n);

    // Newest plugin files known (is_stale) and where this import came from
    let hs = prop(&head, "seen").cloned().unwrap_or(Value::Null);
    for k in ["progress", "killcounts", "containers"] {
        let cur = st.seen.get(k).cloned();
        st.seen.set(k, newer(cur, opt_str(prop(&hs, k))));
    }
    st.seen.bank_at = st.seen.bank_at.max(ps_long(prop(&hs, "bankAt")));
    let from = ps_string(prop(&device, "name"));
    st.imported = Some(json!({
        "from": ps_string(prop(&device, "id")), "name": from, "exported": ps_string(prop(&head, "exported")), "t": iso(now())
    }));
    if let Err(e) = save_state(data, &st) {
        return error(500, &format!("Import failed: {e}"));
    }

    let total: usize = added.iter().filter(|(k, _)| **k != "bankFixed").map(|(_, v)| v).sum();
    let a = |k: &str| added.get(k).copied().unwrap_or(0);
    let mut what = Vec::new();
    for (k, label) in [
        ("history", "hiscores snapshots"),
        ("bank", "bank saves"),
        ("progress", "quest/diary updates"),
        ("clog", "collection log updates"),
        ("loot", "drops"),
        ("kills", "kill count updates"),
        ("pluginFiles", "RuneLite files"),
    ] {
        if a(k) > 0 {
            what.push(format!("{} {label}", a(k)));
        }
    }
    let msg = if total > 0 { format!("Merged from {from}: {}.", what.join(", ")) } else { format!("Already up to date with {from}.") };
    eprintln!(
        "Import from {from}: {} (backup: {})",
        added.iter().map(|(k, v)| format!("{k} {v}")).collect::<Vec<_>>().join(", "),
        backup.display()
    );
    (200, ps_json(&json!({"message": msg})))
}

// ---- Drop log with the other device's drops (server.rs plugin) ----
// A gap with a window ("from" < kill time <= "to") loses the kills (and their items) the other device logged in it;
// a gap left with no kills is dropped. Gaps from before 2026-11-08 have no window and stay as they are.
pub fn gap_fixed(gap_lines: &[String], real_lines: &[String]) -> Vec<String> {
    static RAW: LazyLock<[Regex; 3]> = LazyLock::new(|| {
        [Regex::new(r#""t":"([^"]*)""#).unwrap(), Regex::new(r#""from":"([^"]*)""#).unwrap(), Regex::new(r#""to":"([^"]*)""#).unwrap()]
    });
    let raw = |l: &str, i: usize| RAW[i].captures(l).map(|c| c[1].to_string());
    struct Gap {
        line: String,
        o: Value,
        t: Option<String>,
        win: Option<(String, String, DateTime<Utc>, DateTime<Utc>)>,
    }
    let gaps: Vec<Gap> = gap_lines
        .iter()
        .filter_map(|g| {
            let o: Value = serde_json::from_str(g).ok()?;
            let win = match (raw(g, 1), raw(g, 2)) {
                (Some(f), Some(t)) if !f.is_empty() && !t.is_empty() => {
                    let (ft, tt) = (time_of(Some(&f)), time_of(Some(&t)));
                    Some((f, t, ft, tt))
                }
                _ => None,
            };
            Some(Gap { line: g.clone(), o, t: raw(g, 0), win })
        })
        .collect();
    // Only the real lines inside some window are read
    let mut real: Vec<(DateTime<Utc>, Value)> = Vec::new();
    if gaps.iter().any(|g| g.win.is_some()) {
        for l in real_lines {
            let t = by_t(l);
            if gaps.iter().any(|g| g.win.as_ref().map(|w| t > w.2 && t <= w.3).unwrap_or(false)) {
                if let Ok(v) = serde_json::from_str::<Value>(l) {
                    real.push((t, v));
                }
            }
        }
    }
    let mut out = Vec::new();
    for g in gaps {
        let Some((fs, ts, from, to)) = &g.win else {
            out.push(g.line);
            continue;
        };
        if real.is_empty() {
            out.push(g.line);
            continue;
        }
        let (src, ty) = (ps_string(prop(&g.o, "source")).to_lowercase(), ps_string(prop(&g.o, "type")).to_lowercase());
        let mut kills = 0i64;
        let mut drops: HashMap<String, i64> = HashMap::new();
        for (t, x) in &real {
            if ps_string(prop(x, "source")).to_lowercase() != src || ps_string(prop(x, "type")).to_lowercase() != ty {
                continue;
            }
            if *t <= *from || *t > *to {
                continue;
            }
            kills += 1;
            for it in ps_array(prop(x, "items")) {
                if truthy(&it) && it.as_array().map(|a| a.len() >= 2).unwrap_or(false) {
                    *drops.entry(ps_string(it.get(0))).or_insert(0) += ps_long(it.get(1));
                }
            }
        }
        if kills == 0 {
            out.push(g.line);
            continue;
        }
        let left = ps_long(prop(&g.o, "kills")) - kills;
        if left <= 0 {
            continue;
        }
        let items = match prop(&g.o, "items") {
            None | Some(Value::Null) => Value::Null,
            Some(v) => Value::Array(
                ps_array(Some(v))
                    .iter()
                    .filter(|it| truthy(it) && it.as_array().map(|a| a.len() >= 2).unwrap_or(false))
                    .filter_map(|it| {
                        let id = ps_long(it.get(0));
                        let q = ps_long(it.get(1)) - drops.get(&ps_string(it.get(0))).copied().unwrap_or(0);
                        if q > 0 {
                            Some(json!([id, q]))
                        } else {
                            None
                        }
                    })
                    .collect(),
            ),
        };
        let mut n = Map::new();
        n.insert("t".into(), g.t.clone().map(Value::String).unwrap_or(Value::Null));
        n.insert("source".into(), prop(&g.o, "source").cloned().unwrap_or(Value::Null));
        n.insert("type".into(), prop(&g.o, "type").cloned().unwrap_or(Value::Null));
        n.insert("kills".into(), json!(left));
        n.insert("gap".into(), Value::Bool(true));
        n.insert("from".into(), Value::String(fs.clone()));
        n.insert("to".into(), Value::String(ts.clone()));
        n.insert("items".into(), items);
        out.push(ps_json(&Value::Object(n)));
    }
    out
}

// The drop log lines for the page: this device's, the other device's, and both devices' gaps (fixed), by time
pub fn drops_with_other(data: &Path, own_loot: Vec<String>, own_gaps: Vec<String>, whole: impl Fn(&Path) -> Vec<String>) -> Vec<String> {
    let (lo, go) = (loot_other_file(data), gaps_other_file(data));
    if !lo.exists() && !go.exists() {
        let mut d = own_loot;
        d.extend(own_gaps);
        return d;
    }
    let other = whole(&lo);
    let mut all = own_loot.clone();
    all.extend(other.iter().cloned());
    all.extend(gap_fixed(&own_gaps, &other));
    all.extend(gap_fixed(&whole(&go), &own_loot));
    sort_lines(all, by_t)
}

// ---- Automatic sync through a shared folder ----
// Google Drive (or a folder picked by hand) keeps one file per device in "OSRS Dashboard Sync":
//   "<player> - <device name> (<device id>).osrssync", the same file Export makes, rewritten after every Refresh.
// Before a Refresh (and when the page opens) the other devices' files there are merged in, each only when it is
// newer than the one merged last time (autoSeen) and whole (ends with {"section":"end"}). Nothing else goes online:
// the cloud drive's own app copies the folder between the computers.
const AUTO_DIR: &str = "OSRS Dashboard Sync";

// Google Drive for desktop's "My Drive" folder on this computer
fn google_drive() -> Option<PathBuf> {
    let home = home_dir();
    let dir_ok = |p: &Path| p.is_dir();
    if cfg!(target_os = "macos") {
        // ~/Library/CloudStorage/GoogleDrive-<account>/My Drive (the name is translated in some languages)
        let mut accounts: Vec<PathBuf> = std::fs::read_dir(home.join("Library").join("CloudStorage"))
            .ok()?
            .flatten()
            .map(|e| e.path())
            .filter(|p| dir_ok(p) && p.file_name().map(|n| n.to_string_lossy().starts_with("GoogleDrive-")).unwrap_or(false))
            .collect();
        accounts.sort();
        for a in accounts {
            if dir_ok(&a.join("My Drive")) {
                return Some(a.join("My Drive"));
            }
            let mut subs: Vec<PathBuf> = std::fs::read_dir(&a)
                .ok()?
                .flatten()
                .map(|e| e.path())
                .filter(|p| {
                    let n = p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                    dir_ok(p) && !n.starts_with('.') && n != "Shared drives" && n != "Other computers"
                })
                .collect();
            subs.sort();
            if let Some(d) = subs.into_iter().next() {
                return Some(d);
            }
        }
        None
    } else {
        // Windows: a drive letter (G: by default) holding "My Drive"; mirrored: in the user's folder
        let letters = std::iter::once('G').chain(('D'..='Z').filter(|c| *c != 'G'));
        for c in letters {
            let p = PathBuf::from(format!("{c}:\\My Drive"));
            if dir_ok(&p) {
                return Some(p);
            }
        }
        ["My Drive", "Google Drive"].iter().map(|n| home.join(n)).find(|p| dir_ok(p))
    }
}

// The sync folder: the one picked by hand, else "OSRS Dashboard Sync" in the Google Drive app's folder (None =
// neither, or Google Drive is connected directly: gdrive.rs, no Google Drive app needed)
fn auto_folder(data: &Path, st: &State) -> Option<PathBuf> {
    match &st.folder {
        Some(f) => Some(PathBuf::from(f)).filter(|p| p.is_dir()),
        None if crate::gdrive::connected(data) => None,
        None => google_drive().map(|g| g.join(AUTO_DIR)),
    }
}

struct OtherFile {
    path: PathBuf,
    drive: Option<String>, // the file's id in Google Drive (connected directly) instead of a path
    id: String,
    name: String,
    exported: String,
}

// The other devices' files for this player in the folder, newest per device (a cloud drive can leave copies)
fn auto_files(folder: &Path, player: &str, own_id: &str) -> Vec<OtherFile> {
    let mut by_id: IndexMap<String, OtherFile> = IndexMap::new();
    let Ok(rd) = std::fs::read_dir(folder) else { return Vec::new() };
    let mut paths: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.extension().map(|x| x == "osrssync").unwrap_or(false)).collect();
    paths.sort();
    for p in paths {
        let Some(first) = first_line(&p) else { continue };
        let Ok(h) = serde_json::from_str::<Value>(&first) else { continue };
        if ps_long(prop(&h, "osrsDashboardSync")) != VERSION || norm_player(&ps_string(prop(&h, "player"))) != norm_player(player) {
            continue;
        }
        let dev = prop(&h, "device").cloned().unwrap_or(Value::Null);
        let id = ps_string(prop(&dev, "id"));
        if id.is_empty() || id == own_id {
            continue;
        }
        let f = OtherFile { path: p, drive: None, id: id.clone(), name: ps_string(prop(&dev, "name")), exported: ps_string(prop(&h, "exported")) };
        let newer_file = by_id.get(&id).map(|o| time_of(Some(&f.exported)) > time_of(Some(&o.exported))).unwrap_or(true);
        if newer_file {
            by_id.insert(id, f);
        }
    }
    by_id.into_values().collect()
}

// The other devices' files in Google Drive's app folder (gdrive.rs), from what each upload noted on the file
fn drive_files(data: &Path, player: &str, own_id: &str) -> Result<Vec<OtherFile>, String> {
    let mut by_id: IndexMap<String, OtherFile> = IndexMap::new();
    for f in crate::gdrive::list(data)? {
        let p = |k: &str| ps_string(prop(&f.props, k));
        if p("player") != norm_player(player) || p("device").is_empty() || p("device") == own_id {
            continue;
        }
        let o = OtherFile { path: PathBuf::new(), drive: Some(f.id.clone()), id: p("device"), name: p("name"), exported: p("exported") };
        if by_id.get(&o.id).map(|x| time_of(Some(&o.exported)) > time_of(Some(&x.exported))).unwrap_or(true) {
            by_id.insert(o.id.clone(), o);
        }
    }
    Ok(by_id.into_values().collect())
}

// Every other device's file this device can reach: the sync folder and/or Google Drive. Errors go in `err`.
fn other_files(data: &Path, player: &str, st: &State, err: &mut Option<String>) -> Vec<OtherFile> {
    let mut all = auto_folder(data, st).map(|f| auto_files(&f, player, &st.id)).unwrap_or_default();
    if crate::gdrive::connected(data) {
        match drive_files(data, player, &st.id) {
            Ok(d) => all.extend(d),
            Err(e) => *err = Some(format!("Google Drive: {e}")),
        }
    }
    all
}

fn first_line(p: &Path) -> Option<String> {
    use std::io::BufRead;
    let f = std::fs::File::open(p).ok()?;
    let mut l = String::new();
    std::io::BufReader::new(f).read_line(&mut l).ok()?;
    Some(trim(l.trim_start_matches('\u{feff}')).to_string())
}

// Merges the other devices' newer files: {"imported":[messages],"error"}
pub fn auto_import(data: &Path, player: &str) -> Value {
    if player.is_empty() {
        return json!({"imported": [], "error": Value::Null});
    }
    let st = load_state(data);
    let mut msgs = Vec::new();
    let mut err: Option<String> = None;
    for o in other_files(data, player, &st, &mut err) {
        let done = load_state(data).auto_seen.get(&o.id).map(|t| time_of(Some(t)) >= time_of(Some(&o.exported))).unwrap_or(false);
        if done {
            continue;
        }
        let text = match &o.drive {
            Some(id) => match crate::gdrive::download(data, id) {
                Ok(t) => t,
                Err(e) => {
                    err = Some(format!("Google Drive: {e}"));
                    continue;
                }
            },
            None => match std::fs::read(&o.path) {
                Ok(b) => String::from_utf8_lossy(&b).into_owned(),
                Err(_) => continue,
            },
        };
        // Not whole yet (still being copied by the cloud drive): next time
        if text.trim_end().lines().last().map(trim) != Some(END_LINE) {
            continue;
        }
        let (code, body) = import(data, player, text.as_bytes());
        let b: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
        if code == 200 {
            let mut st = load_state(data);
            st.auto_seen.insert(o.id.clone(), o.exported.clone());
            st.auto_error = None;
            let _ = save_state(data, &st);
            msgs.push(Value::String(ps_string(prop(&b, "message"))));
        } else {
            err = Some(format!("{}: {}", o.name, ps_string(prop(&b, "error"))));
        }
    }
    if let Some(e) = &err {
        let mut st = load_state(data);
        st.auto_error = Some(e.clone());
        let _ = save_state(data, &st);
        eprintln!("Automatic sync: {e}");
    }
    json!({"imported": msgs, "error": err})
}

// Rewrites this device's file in the sync folder (after a Refresh)
pub fn auto_export(data: &Path, player: &str) -> Value {
    if player.is_empty() {
        return Value::Null;
    }
    let mut st = load_state(data);
    let folder = auto_folder(data, &st);
    let drive = crate::gdrive::connected(data);
    if folder.is_none() && !drive {
        return Value::Null;
    }
    let now_s = iso(now());
    let (text, _) = export_text(data, player, &st, &now_s);
    static NOT_FILE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"[^A-Za-z0-9 _-]"#).unwrap());
    let name = format!("{} - {} ({}).osrssync", NOT_FILE.replace_all(player, ""), trim(&NOT_FILE.replace_all(&st.name, "")), st.id);
    st.auto_error = None;
    if drive {
        let short: String = st.name.chars().take(40).collect();
        let props = json!({"player": norm_player(player), "device": st.id, "name": short, "exported": now_s});
        match crate::gdrive::upload(data, &name, &text, props) {
            Ok(()) => {
                st.auto_exported = Some(now_s.clone());
                eprintln!("Automatic sync: saved {name} to Google Drive");
            }
            Err(e) => {
                st.auto_error = Some(format!("Google Drive: could not save ({e})"));
                eprintln!("Automatic sync: {}", st.auto_error.as_ref().unwrap());
            }
        }
    }
    let Some(folder) = folder else {
        let _ = save_state(data, &st);
        return json!({"drive": true});
    };
    ensure_dir(&folder);
    let file = folder.join(&name);
    let part = folder.join(format!("{name}.part"));
    let res = write_text(&part, &text).and_then(|_| std::fs::rename(&part, &file));
    match res {
        Ok(()) => {
            st.auto_exported = Some(now_s);
            eprintln!("Automatic sync: saved {}", file.display());
        }
        Err(e) => {
            let _ = std::fs::remove_file(&part);
            st.auto_error = Some(format!("Could not save to {}: {e}", folder.display()));
            eprintln!("Automatic sync: {}", st.auto_error.as_ref().unwrap());
        }
    }
    let _ = save_state(data, &st);
    json!({"path": file.display().to_string()})
}

// POST /api/sync-folder {"folder": "<path>"} picks the folder; "" = back to Google Drive
pub fn set_folder(data: &Path, body: &[u8]) -> (u16, String) {
    let v: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    let f = trim(&ps_string(prop(&v, "folder"))).to_string();
    let mut st = load_state(data);
    if f.is_empty() {
        st.folder = None;
    } else {
        if !Path::new(&f).is_dir() {
            return error(400, &format!("That folder doesn't exist: {f}"));
        }
        st.folder = Some(f);
    }
    st.auto_error = None;
    if let Err(e) = save_state(data, &st) {
        return error(500, &format!("Could not save: {e}"));
    }
    (200, r#"{"ok":true}"#.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bank_seen_parses_both_forms() {
        let a = bank_seen(r#"{"t":"x","saved":"09:05:00, 7 Nov 2026","items":[]}"#).unwrap();
        let b = bank_seen(r#"{"t":"x","saved":"before 14:30:00, 18 Nov 2026","items":[]}"#).unwrap();
        assert!(a < b);
    }

    #[test]
    fn gap_loses_the_other_devices_kills() {
        let gap = r#"{"t":"2026-11-08T14:30:00.000Z","source":"Goblin","type":"NPC","kills":4,"gap":true,"from":"2026-11-07T10:00:00.000Z","to":"2026-11-08T17:00:00.000Z","items":[[995,25],[526,3]]}"#;
        let real: Vec<String> = ["14:10", "14:20", "14:30"]
            .iter()
            .map(|t| format!(r#"{{"t":"2026-11-08T{t}:00.000Z","source":"Goblin","type":"NPC","value":5,"items":[[995,5,1],[526,1,0]]}}"#))
            .collect();
        let out = gap_fixed(&[gap.to_string()], &real);
        assert_eq!(
            out,
            vec![r#"{"t":"2026-11-08T14:30:00.000Z","source":"Goblin","type":"NPC","kills":1,"gap":true,"from":"2026-11-07T10:00:00.000Z","to":"2026-11-08T17:00:00.000Z","items":[[995,10]]}"#]
        );
        // A gap without a window is left alone
        let old = r#"{"t":"2026-10-20T10:00:00.000Z","source":"Goblin","type":"NPC","kills":2,"gap":true,"items":null}"#;
        assert_eq!(gap_fixed(&[old.to_string()], &real), vec![old.to_string()]);
    }
}
