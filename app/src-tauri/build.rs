// Before Tauri's own build step: gathers what the installer ships into app\bundle\dashboard (tauri.conf.json
// "resources"). The same allow-list as tools\make-release.ps1: the page, fonts + chart library, the saved pictures and
// the reference lists every player needs. NEVER anyone's data (history, bank, collection log, kills, prices,
// settings): only allow-listed files are copied, and the build stops if a personal file or the builder's player name
// / user folder turns up in the copy anyway. Works the same on Windows and Mac (no PowerShell needed).

use std::fs;
use std::path::{Path, PathBuf};

const FILES: &[&str] = &["index.html", "styles.css", "app.js"];
const FOLDERS: &[&str] = &["vendor", "icons"];
// Reference lists (the same for every player), copied into a new user's data folder on the first start
const STARTER: &[&str] = &[
    "data/bank/mapping.json",
    "data/clog/categories.json",
    "data/clog/images.json",
    "data/clog/items.json",
    "data/progress/ca-tasks.json",
    "data/progress/diary-tasks.json",
    "data/progress/miniquests.json",
    "data/plugin/npc-images.json",
];
const MAX_NAME: usize = 100;
const BANNED_NAMES: &[&str] = &["settings.json", "credentials.properties", "kills-history.jsonl", "gear.json", "latest.json"];

// Copies a file unless the copy is already up to date (same size, not older)
fn copy(src: &Path, dst: &Path) {
    let (Ok(s), d) = (fs::metadata(src), fs::metadata(dst)) else { return };
    if let Ok(d) = d {
        if d.len() == s.len() && d.modified().ok() >= s.modified().ok() {
            return;
        }
    }
    fs::create_dir_all(dst.parent().unwrap()).unwrap();
    fs::copy(src, dst).unwrap_or_else(|e| panic!("copy {}: {e}", src.display()));
}

fn copy_tree(src: &Path, dst: &Path) {
    for e in fs::read_dir(src).unwrap_or_else(|e| panic!("{}: {e}", src.display())).flatten() {
        let p = e.path();
        if p.is_dir() {
            copy_tree(&p, &dst.join(e.file_name()));
        } else if e.file_name().len() > MAX_NAME {
            // A name this long (wiki text that ended up in a monster name) breaks Windows' 260-character path limit
            // once installed; the app downloads such a picture itself if it is ever needed
            let _ = fs::remove_file(dst.join(e.file_name()));
        } else {
            copy(&p, &dst.join(e.file_name()));
        }
    }
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, out)
            } else {
                out.push(p)
            }
        }
    }
}

// Nothing personal in the bundle: banned file names, history/price/backup files, the builder's player name and
// user folder in any text file
fn check(bundle: &Path, project: &Path) {
    let mut files = Vec::new();
    walk(bundle, &mut files);
    let player = fs::read_to_string(project.join("settings.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(t.trim_start_matches('\u{feff}')).ok())
        .and_then(|v| v.get("player").and_then(|p| p.as_str()).map(|s| s.trim().to_lowercase()))
        .filter(|p| p.len() >= 3);
    let user = std::env::var("USERNAME").or_else(|_| std::env::var("USER")).ok().map(|u| u.to_lowercase());
    let mut bad = Vec::new();
    for f in &files {
        let name = f.file_name().unwrap().to_string_lossy().to_lowercase();
        let rel = f.strip_prefix(bundle).unwrap().to_string_lossy().replace('\\', "/");
        if BANNED_NAMES.contains(&name.as_str())
            || (name.starts_with("history") && name.ends_with(".jsonl"))
            || name.starts_with("prices")
            || name.contains(".backup")
            || name.contains(".before")
            || rel.ends_with("data/bank/items.json")
            || rel.ends_with("data/bank/slots.json")
            || rel.ends_with("data/bank/derived.json")
        {
            bad.push(format!("{rel}: personal file"));
            continue;
        }
        let text_kind = ["json", "js", "html", "css", "md", "txt"].iter().any(|x| name.ends_with(&format!(".{x}")));
        if !text_kind {
            continue;
        }
        let text = fs::read_to_string(f).unwrap_or_default().to_lowercase();
        if let Some(p) = &player {
            let hit = text.match_indices(p.as_str()).any(|(i, _)| {
                let before = text[..i].chars().last().map(|c| c.is_alphanumeric() || c == '_').unwrap_or(false);
                let after = text[i + p.len()..].chars().next().map(|c| c.is_alphanumeric() || c == '_').unwrap_or(false);
                !before && !after
            });
            if hit {
                bad.push(format!("{rel}: mentions the player name"));
            }
        }
        if let Some(u) = &user {
            if text.contains(&format!("users\\{u}")) || text.contains(&format!("users/{u}")) || text.contains(&format!("users\\\\{u}")) {
                bad.push(format!("{rel}: has the builder's user folder"));
            }
        }
    }
    if !bad.is_empty() {
        panic!("NOT bundled - personal things found:\n  {}", bad.join("\n  "));
    }
}

// Google Drive sync (src/gdrive.rs): the OAuth "Desktop app" client from Google Cloud, downloaded as
// google-client.json next to this file (gitignored: the repository is public). Built into the app; without the file
// the app is built without Google Drive (the Sync panel says so).
fn google_client(here: &Path) {
    let f = here.join("google-client.json");
    println!("cargo:rerun-if-changed=google-client.json");
    let Ok(t) = fs::read_to_string(&f) else { return };
    let v: serde_json::Value = serde_json::from_str(t.trim_start_matches('\u{feff}')).unwrap_or_else(|e| panic!("google-client.json: {e}"));
    let c = v.get("installed").unwrap_or_else(|| panic!("google-client.json: not a Desktop app client (no \"installed\")"));
    let get = |k: &str| c.get(k).and_then(|x| x.as_str()).unwrap_or_else(|| panic!("google-client.json: no {k}")).to_string();
    println!("cargo:rustc-env=OSRS_GOOGLE_CLIENT_ID={}", get("client_id"));
    println!("cargo:rustc-env=OSRS_GOOGLE_CLIENT_SECRET={}", get("client_secret"));
}

fn main() {
    let here = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let project = here.join("..").join("..");
    let bundle = here.join("..").join("bundle").join("dashboard");
    for f in FILES {
        copy(&project.join(f), &bundle.join(f));
        println!("cargo:rerun-if-changed=../../{f}");
    }
    for d in FOLDERS {
        copy_tree(&project.join(d), &bundle.join(d));
        println!("cargo:rerun-if-changed=../../{d}");
    }
    for f in STARTER {
        let src = project.join(f);
        if src.exists() {
            copy(&src, &bundle.join("starter").join(f));
        }
        println!("cargo:rerun-if-changed=../../{f}");
    }
    check(&bundle, &project);
    google_client(&here);
    tauri_build::build()
}
