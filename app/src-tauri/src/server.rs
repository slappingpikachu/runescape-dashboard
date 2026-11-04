// Answers the page's requests, the same way server.ps1 (+ clog.ps1, bank.ps1, progress.ps1, plugin.ps1) does.
// Every answer is built exactly like the PowerShell version builds it (same JSON text), so the page can't tell the
// difference; tools\parity-test.ps1 compares the two.
//
// Refresh, setup and the Wise Old Man import are in refresh.rs; a picture that isn't saved yet is downloaded from the
// OSRS Wiki once (icons.rs). One Refresh / setup / import runs at a time.

use crate::icons::Icons;
use crate::net::Web;
use crate::refresh::{self, Settings};
use crate::util::{non_empty, ps_str, read_lines, read_text, split_lines, trim};
use regex::Regex;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::Instant;
use tauri::http::{Request, Response};

pub struct Dashboard {
    root: PathBuf,
    pages: PathBuf,
    web: Web,
    icons: Icons,
    settings: Mutex<Settings>,
    // Held while a Refresh / setup / import runs; the time of the last hiscores request (60 s cooldown)
    work: Mutex<Option<Instant>>,
}

type Answer = Response<Vec<u8>>;

const JSON: &str = "application/json";

// ---- responses ----

fn respond(status: u16, content_type: &str, body: Vec<u8>, cache: &str) -> Answer {
    Response::builder()
        .status(status)
        .header("Content-Type", content_type)
        .header("Cache-Control", cache)
        .body(body)
        .unwrap()
}
fn text(status: u16, content_type: &str, body: String) -> Answer {
    respond(status, content_type, body.into_bytes(), "no-store")
}
fn data(content_type: &str, body: String) -> Answer {
    respond(200, content_type, body.into_bytes(), "no-cache")
}
fn bytes(content_type: &str, body: Vec<u8>) -> Answer {
    respond(200, content_type, body, "max-age=2592000, immutable") // pictures and fonts never change
}
fn not_found(what: &str) -> Answer {
    text(404, "text/plain", format!("{what} not found"))
}
fn picture(b: Option<Vec<u8>>) -> Answer {
    match b {
        Some(b) => bytes("image/png", b),
        None => not_found("Icon"),
    }
}

static ITEM_ICON: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^/icons/item/([0-9]+)\.png$").unwrap());
static NPC_ICON: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^/icons/npc/([a-z0-9-]+)\.png$").unwrap());
static CA_ICON: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^/icons/ca/([a-z0-9]+)\.png$").unwrap());
static WIKI_ICON: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^/icons/(skill|wiki)/([A-Za-z0-9_()'-]+)\.png$").unwrap());
static FONT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^/vendor/fonts/([a-z0-9-]+)\.woff2$").unwrap());
static CA_LIST: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""ca":\[[0-9,]*\]"#).unwrap());
static CA_TIME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""timestamp":"([^"]*)""#).unwrap());
static MAP_HEAD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"^\{"t":"[^"]*","map":"#).unwrap());

impl Dashboard {
    pub fn new(l: &crate::layout::Layout) -> Self {
        Dashboard {
            web: Web::new(),
            icons: Icons::new(&l.root, l.bundled_icons.clone()),
            settings: Mutex::new(refresh::load_settings(&l.root)),
            work: Mutex::new(None),
            root: l.root.clone(),
            pages: l.pages.clone(),
        }
    }

    fn data_dir(&self) -> PathBuf {
        self.root.join("data")
    }

    pub fn handle(&self, req: &Request<Vec<u8>>) -> Answer {
        let path = req.uri().path().to_string();
        let get = req.method() == "GET";
        match (get, path.as_str()) {
            (true, "/api/history") => data(JSON, self.history()),
            (true, "/api/clog") => data(JSON, self.clog()),
            (true, "/api/bank") => data(JSON, self.bank()),
            (true, "/api/miniquests") => data(JSON, self.progress_file("miniquests.json", "[]")),
            (true, "/api/diary-tasks") => data(JSON, self.progress_file("diary-tasks.json", "null")),
            (true, "/api/quest-reqs") => data(JSON, self.progress_file("quest-reqs.json", "null")),
            (true, "/api/ca-tasks") => data(JSON, self.progress_file("ca-tasks.json", "null")),
            (true, "/api/ca-history") => data(JSON, self.ca_history()),
            (true, "/api/progress") => data(JSON, self.progress_file("latest.json", "null")),
            (true, "/api/settings") => text(200, JSON, self.settings_json()),
            (true, "/api/plugin") => data(JSON, self.plugin()),
            (false, "/api/refresh") => {
                let player = self.settings.lock().unwrap().player.clone();
                let mut last = self.work.lock().unwrap_or_else(|e| e.into_inner());
                let (status, body) = refresh::refresh(&self.root, &self.web, &self.icons, &player, &mut last);
                if status == 200 {
                    data(JSON, self.history())
                } else {
                    text(status, JSON, body)
                }
            }
            (false, "/api/setup") => {
                let mut last = self.work.lock().unwrap_or_else(|e| e.into_inner());
                let (status, body) = refresh::setup(&self.root, &self.web, &self.icons, &self.settings, &mut last, req.body());
                if status == 200 {
                    data(JSON, self.history())
                } else {
                    text(status, JSON, body)
                }
            }
            (false, "/api/wom") => {
                let _busy = self.work.lock().unwrap_or_else(|e| e.into_inner());
                let (status, body) = refresh::wom(&self.root, &self.web, &self.settings, req.body());
                text(status, JSON, body)
            }
            _ => self.file(&path),
        }
    }

    // ---- pages, fonts and pictures ----

    fn file(&self, path: &str) -> Answer {
        let statics: &[(&str, &str, &str)] = &[
            ("/", "index.html", "text/html; charset=utf-8"),
            ("/index.html", "index.html", "text/html; charset=utf-8"),
            ("/styles.css", "styles.css", "text/css; charset=utf-8"),
            ("/app.js", "app.js", "application/javascript; charset=utf-8"),
            ("/vendor/chart.umd.min.js", "vendor/chart.umd.min.js", "application/javascript; charset=utf-8"),
            ("/vendor/fonts.css", "vendor/fonts.css", "text/css; charset=utf-8"),
        ];
        if let Some((_, file, kind)) = statics.iter().find(|(p, _, _)| *p == path) {
            return match read_text(&self.pages.join(file)) {
                Some(t) => data(kind, t),
                None => not_found("File"),
            };
        }
        if let Some(m) = ITEM_ICON.captures(path) {
            return picture(self.icons.get_item(&self.web, &self.data_dir(), &m[1]));
        }
        // Monster pictures are saved on Refresh, combat achievement icons by tools\fetch-ca-icons.ps1: disk only
        if let Some(m) = NPC_ICON.captures(path) {
            return picture(self.icons.read("npc", &format!("{}.png", &m[1])));
        }
        if let Some(m) = CA_ICON.captures(path) {
            return picture(self.icons.read("ca", &format!("{}.png", &m[1])));
        }
        let decoded = percent_encoding::percent_decode_str(path).decode_utf8_lossy().into_owned();
        if let Some(m) = WIKI_ICON.captures(&decoded) {
            return picture(self.icons.get_wiki(&self.web, &m[1], &m[2]));
        }
        if let Some(m) = FONT.captures(path) {
            return match fs::read(self.pages.join("vendor").join("fonts").join(format!("{}.woff2", &m[1]))) {
                Ok(b) => bytes("font/woff2", b),
                Err(_) => not_found("Font"),
            };
        }
        text(404, "text/plain", "Not found".into())
    }

    // ---- settings.json: {"player": "Name", "womAsked": true|false} (kept in memory, like server.ps1) ----

    fn settings(&self) -> (String, bool) {
        let s = self.settings.lock().unwrap();
        (s.player.clone(), s.wom_asked)
    }

    // GET /api/settings: womOffer = show the "Import from Wise Old Man?" banner
    fn settings_json(&self) -> String {
        let (player, wom_asked) = self.settings();
        let imported = read_text(&self.data_dir().join("history.jsonl"))
            .map(|t| t.contains(r#""src":"wom""#))
            .unwrap_or(false);
        let offer = !player.is_empty() && !wom_asked && !imported;
        let name = if player.is_empty() { "null".to_string() } else { ps_str(&player) };
        format!(r#"{{"player":{name},"womOffer":{offer}}}"#)
    }

    // ---- data\history.jsonl: one hiscores snapshot per line ----

    fn history(&self) -> String {
        match read_text(&self.data_dir().join("history.jsonl")) {
            None => "[]".into(),
            Some(t) => format!("[{}]", split_lines(&t).join(",")),
        }
    }

    // ---- data\clog (clog.ps1 Get-ClogJson) ----

    fn clog(&self) -> String {
        let dir = self.data_dir().join("clog");
        let hist = read_text(&dir.join("history.jsonl")).unwrap_or_default();
        let names = non_empty(read_text(&dir.join("items.json"))).unwrap_or_else(|| r#"{"items":{}}"#.into());
        let cats = non_empty(read_text(&dir.join("categories.json"))).unwrap_or_else(|| "{}".into());
        let prices = non_empty(read_text(&dir.join("prices.json"))).unwrap_or_else(|| "null".into());
        format!(
            r#"{{"history":[{}],"names":{names},"categories":{cats},"prices":{prices}}}"#,
            split_lines(&hist).join(",")
        )
    }

    // ---- data\bank (bank.ps1 Get-BankJson) ----

    fn bank(&self) -> String {
        let dir = self.data_dir().join("bank");
        let read = |name: &str| non_empty(read_text(&dir.join(name)));
        let hist = read_text(&dir.join("history.jsonl")).unwrap_or_default();
        let or = |v: Option<String>, d: &str| v.unwrap_or_else(|| d.to_string());
        // mapping.json is {"t":..,"map":{...}}: only the map goes to the page. Like PowerShell's -replace '\}$', '':
        // the last "}" goes, also when a line break follows it.
        let mapping = match read("mapping.json") {
            Some(m) => {
                let m = MAP_HEAD.replace(&m, "").into_owned();
                if let Some(s) = m.strip_suffix("}\n") {
                    format!("{s}\n")
                } else if let Some(s) = m.strip_suffix('}') {
                    s.to_string()
                } else {
                    m
                }
            }
            None => "{}".into(),
        };
        let saves = read("prices-saves.jsonl").map(|s| split_lines(&s).join(",")).unwrap_or_default();
        format!(
            r#"{{"history":[{}],"items":{},"prices":{},"mapping":{},"derived":{},"slots":{},"gear":{},"live":{},"reset":{},"past":{},"days":{},"saves":[{}]}}"#,
            split_lines(&hist).join(","),
            or(read("items.json"), "{}"),
            or(read("prices.json"), "null"),
            mapping,
            or(read("derived.json"), "{}"),
            or(read("slots.json"), "{}"),
            or(read("gear.json"), "null"),
            or(read("prices-live.json"), "null"),
            or(read("prices-reset.json"), "null"),
            or(read("prices-past.json"), "null"),
            or(read("prices-days.json"), "{}"),
            saves
        )
    }

    // ---- data\progress (progress.ps1) ----

    fn progress_file(&self, name: &str, missing: &str) -> String {
        read_text(&self.data_dir().join("progress").join(name)).unwrap_or_else(|| missing.to_string())
    }

    // Each change of the finished combat achievement list: [{"t":sync time,"ca":[ids]},...]
    fn ca_history(&self) -> String {
        let f = self.data_dir().join("progress").join("history.jsonl");
        if !f.is_file() {
            return "[]".into();
        }
        let mut out = Vec::new();
        let mut prev = String::new();
        for line in read_lines(&f) {
            let Some(ca) = CA_LIST.find(&line).map(|m| m.as_str().to_string()) else { continue };
            if ca == prev {
                continue;
            }
            let t = CA_TIME.captures(&line).map(|c| c[1].to_string()).unwrap_or_default();
            out.push(format!(r#"{{"t":"{t}",{ca}}}"#));
            prev = ca;
        }
        format!("[{}]", out.join(","))
    }

    // ---- the OSRS Data Sync plugin's files (plugin.ps1 Get-PluginJson) ----

    fn plugin(&self) -> String {
        let (player, _) = self.settings();
        let dir = refresh::plugin_dir(&player);
        if !dir.exists() {
            return "null".into();
        }
        // A plugin file as it is; an empty or cut-off file is sent as null so the answer stays valid JSON
        let read = |n: &str| -> String {
            match read_text(&dir.join(n)) {
                None => "null".into(),
                Some(t) => {
                    let t = trim(&t);
                    if t.starts_with('{') && t.ends_with('}') {
                        t.to_string()
                    } else {
                        "null".into()
                    }
                }
            }
        };
        // Drop log: whole loot.jsonl lines, then the kills done without the plugin; the newest 5000
        let whole = |f: &Path| -> Vec<String> {
            read_lines(f)
                .iter()
                .map(|l| trim(l).to_string())
                .filter(|l| l.starts_with(r#"{"t":""#) && l.ends_with('}'))
                .collect()
        };
        let plugin_data = self.data_dir().join("plugin");
        let mut drops = whole(&dir.join("loot.jsonl"));
        drops.extend(whole(&plugin_data.join("loot-gaps.jsonl")));
        let max = 5000;
        let drops = if drops.len() > max { drops[drops.len() - max..].join(",") } else { drops.join(",") };
        let hist: Vec<String> =
            read_lines(&plugin_data.join("kills-history.jsonl")).into_iter().filter(|l| !trim(l).is_empty()).collect();
        // In folder-listing order (whole file names, ignoring case: "x-hard.png" before "x.png"), like Get-ChildItem
        let mut files: Vec<String> = self.icons.list("npc").into_iter().filter(|n| n.ends_with(".png")).collect();
        files.sort_by_key(|n| n.to_uppercase());
        let slugs: Vec<&str> = files.iter().map(|n| n.trim_end_matches(".png")).collect();
        let icons = format!("[{}]", slugs.iter().map(|s| ps_str(s)).collect::<Vec<_>>().join(","));
        format!(
            r#"{{"progress":{},"kills":{},"clog":{},"containers":{},"drops":[{drops}],"killHistory":[{}],"npcIcons":{icons}}}"#,
            read("progress.json"),
            read("killcounts.json"),
            read("clog.json"),
            read("containers.json"),
            hist.join(",")
        )
    }
}
