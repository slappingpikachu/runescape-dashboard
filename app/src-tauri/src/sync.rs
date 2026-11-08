// Export / Import between your own devices (sync.ps1: what is merged and why is described there). The same files and
// the same results as the PowerShell version; tools\parity-test.ps1 can compare the two.
//
//   POST /api/export  one file in Downloads with this device's history (for Import on the other device)
//   POST /api/import  body = such a file from another device, merged into this device's data
//   GET  /api/sync    {"device","exported","imported"} for the page

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
        "imported": st.imported.clone().unwrap_or(Value::Null)
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

pub fn status(data: &Path) -> String {
    let st = load_state(data);
    ps_json(&json!({
        "device": st.name,
        "exported": st.exported.map(Value::String).unwrap_or(Value::Null),
        "imported": st.imported.unwrap_or(Value::Null)
    }))
}

fn error(status: u16, msg: &str) -> (u16, String) {
    (status, format!(r#"{{"error":{}}}"#, ps_str(msg)))
}

// ---- Export ----

pub fn export(data: &Path, player: &str) -> (u16, String) {
    if player.is_empty() {
        return error(400, "Set up your player name first.");
    }
    let mut st = load_state(data);
    let now_s = iso(now());
    let plugin = plugin_dir(player);
    let head = json!({
        "osrsDashboardSync": VERSION, "player": player, "device": {"id": st.id, "name": st.name},
        "exported": now_s, "seen": seen_now(&st, &plugin).json()
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
