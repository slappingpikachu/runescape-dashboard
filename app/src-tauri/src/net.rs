// Every download the app makes goes through here. Only these sites can be reached (anything else is refused before
// a connection is made): the official hiscores, the OSRS Wiki (names, pictures, recipes) and its price API, and Wise
// Old Man (only when the player chooses to import). Nothing is ever uploaded.
//
// For the parity tests (phase 3) downloads can be recorded to a folder (OSRS_DASH_NET_RECORD=<dir>) or answered
// from one without any network (OSRS_DASH_NET_REPLAY=<dir>); tools\parity-test.ps1 feeds the PowerShell version
// the same recordings, so both see exactly the same answers.

use crate::util::{trim, Res};
use regex::Regex;
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

pub const UA: &str = "osrs-progress-dashboard/1.0 (self-hosted OSRS progress dashboard)";
// The hiscores answer the same client string the PowerShell version sends
pub const HISCORE_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) WindowsPowerShell/5.1";
const ALLOWED: [&str; 4] = ["secure.runescape.com", "oldschool.runescape.wiki", "prices.runescape.wiki", "api.wiseoldman.net"];

pub struct Web {
    agent: ureq::Agent,
    // During a Refresh: answers already downloaded (Get-Web's $Prefetch), so each URL is fetched once per Refresh
    prefetch: Mutex<Option<HashMap<String, String>>>,
    tape: Option<Tape>,
}

struct Tape {
    dir: PathBuf,
    record: bool,
    index: Mutex<HashMap<String, (String, u16)>>,
}

// A download's result: HTTP status (0 = no connection / not allowed) and the body when it was 2xx
pub struct Got {
    pub status: u16,
    pub body: Option<Vec<u8>>,
}

impl Got {
    pub fn text(&self) -> Option<String> {
        self.body.as_ref().map(|b| String::from_utf8_lossy(b).into_owned())
    }
}

fn host_of(url: &str) -> &str {
    let rest = url.strip_prefix("https://").unwrap_or("");
    rest.split(['/', '?', ':']).next().unwrap_or("")
}

static OR_TERMS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"bucket\.Or\((.*)\)\)\.limit").unwrap());
static TERM: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\{'[^']*','(?:[^'\\]|\\.)*'\}").unwrap());

// Recording key: the URL, with a wiki query's look-up list sorted (the same request, whatever order the names were in)
pub fn tape_key(url: &str) -> String {
    let decoded = percent_encoding::percent_decode_str(url).decode_utf8_lossy().into_owned();
    OR_TERMS
        .replace(&decoded, |c: &regex::Captures| {
            let mut terms: Vec<&str> = TERM.find_iter(&c[1]).map(|m| m.as_str()).collect();
            terms.sort();
            format!("bucket.Or({})).limit", terms.join(","))
        })
        .into_owned()
}

impl Tape {
    fn open(dir: PathBuf, record: bool) -> Tape {
        let _ = fs::create_dir_all(&dir);
        let mut index = HashMap::new();
        if let Ok(t) = fs::read_to_string(dir.join("index.tsv")) {
            for l in t.lines() {
                let p: Vec<&str> = l.split('\t').collect();
                if p.len() == 3 {
                    index.insert(p[0].to_string(), (p[1].to_string(), p[2].parse().unwrap_or(0)));
                }
            }
        }
        Tape { dir, record, index: Mutex::new(index) }
    }
    fn get(&self, url: &str) -> Option<Got> {
        let idx = self.index.lock().unwrap();
        let (file, status) = idx.get(&tape_key(url))?;
        let body = if (200..300).contains(status) { fs::read(self.dir.join(file)).ok() } else { None };
        Some(Got { status: *status, body })
    }
    fn put(&self, url: &str, got: &Got) {
        let key = tape_key(url);
        let mut idx = self.index.lock().unwrap();
        if idx.contains_key(&key) {
            return;
        }
        let file = format!("{}.bin", idx.len() + 1);
        if let Some(b) = &got.body {
            let _ = fs::write(self.dir.join(&file), b);
        }
        let _ = crate::util::append_text(&self.dir.join("index.tsv"), &format!("{key}\t{file}\t{}\n", got.status));
        idx.insert(key, (file, got.status));
    }
    fn missing(&self, url: &str) {
        let _ = crate::util::append_text(&self.dir.join("missing.txt"), &format!("{url}\n"));
    }
}

impl Web {
    pub fn new() -> Web {
        let tape = match (std::env::var_os("OSRS_DASH_NET_RECORD"), std::env::var_os("OSRS_DASH_NET_REPLAY")) {
            (Some(d), _) => Some(Tape::open(PathBuf::from(d), true)),
            (None, Some(d)) => Some(Tape::open(PathBuf::from(d), false)),
            _ => None,
        };
        Web {
            agent: ureq::AgentBuilder::new().timeout(Duration::from_secs(30)).redirects(5).build(),
            prefetch: Mutex::new(None),
            tape,
        }
    }

    // One download (no prefetch): status + body
    pub fn fetch(&self, url: &str, ua: &str) -> Got {
        if !ALLOWED.contains(&host_of(url)) {
            eprintln!("Blocked a download from a site the dashboard doesn't use: {url}");
            return Got { status: 0, body: None };
        }
        if let Some(t) = &self.tape {
            if let Some(g) = t.get(url) {
                return g;
            }
            if !t.record {
                t.missing(url);
                return Got { status: 0, body: None };
            }
        }
        let got = match self.agent.get(url).set("User-Agent", ua).call() {
            Ok(res) => {
                let status = res.status();
                let mut body = Vec::new();
                match res.into_reader().take(200 * 1024 * 1024).read_to_end(&mut body) {
                    Ok(_) => Got { status, body: Some(body) },
                    Err(_) => Got { status: 0, body: None },
                }
            }
            Err(ureq::Error::Status(code, _)) => Got { status: code, body: None },
            Err(_) => Got { status: 0, body: None },
        };
        if let Some(t) = &self.tape {
            t.put(url, &got);
        }
        got
    }

    // Get-Web: the text of a URL (the Refresh's copy if it has one), an error unless the site answered 2xx
    pub fn get(&self, url: &str) -> Res<String> {
        if let Some(p) = self.prefetch.lock().unwrap().as_ref() {
            if let Some(t) = p.get(url) {
                return Ok(t.clone());
            }
        }
        let got = self.fetch(url, UA);
        let text = match (got.status, got.text()) {
            (200..=299, Some(t)) => t,
            (0, _) => return Err(format!("Could not connect to {}", host_of(url))),
            (s, _) => return Err(format!("The remote server returned an error: ({s}).")),
        };
        if let Some(p) = self.prefetch.lock().unwrap().as_mut() {
            p.insert(url.to_string(), text.clone());
        }
        Ok(text)
    }

    pub fn get_json(&self, url: &str) -> Res<serde_json::Value> {
        let t = self.get(url)?;
        serde_json::from_str(trim(&t)).map_err(|e| format!("Invalid JSON from {}: {e}", host_of(url)))
    }

    // Several downloads at once (the Refresh starts the hiscores and price downloads together)
    pub fn fetch_all(&self, jobs: &[(String, &str)]) -> Vec<Got> {
        std::thread::scope(|s| {
            let handles: Vec<_> = jobs.iter().map(|(u, ua)| s.spawn(move || self.fetch(u, ua))).collect();
            handles.into_iter().map(|h| h.join().unwrap_or(Got { status: 0, body: None })).collect()
        })
    }

    pub fn start_refresh(&self, got: HashMap<String, String>) {
        *self.prefetch.lock().unwrap() = Some(got);
    }
    pub fn end_refresh(&self) {
        *self.prefetch.lock().unwrap() = None;
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn key_sorts_terms() {
        let a = super::tape_key("https://x/api.php?action=bucket&query=bucket('a').where(bucket.Or(%7B'item_id'%2C'2'%7D%2C%7B'item_id'%2C'1'%7D)).limit(500)");
        let b = super::tape_key("https://x/api.php?action=bucket&query=bucket('a').where(bucket.Or(%7B'item_id'%2C'1'%7D%2C%7B'item_id'%2C'2'%7D)).limit(500)");
        assert_eq!(a, b);
    }
}
