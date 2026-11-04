// Where the app finds the page and where it keeps the data.
//
//   pages  index.html, app.js, styles.css, vendor\ (and the shipped pictures in icons\)
//   root   data\, settings.json, icons\ (pictures downloaded later) - the same layout as the PowerShell version
//
// In order:
//   1. --root <folder> or OSRS_DASHBOARD_ROOT: that dashboard folder (the page from it too, if it has one)
//   2. a folder at or above the app with index.html + app.js: a dashboard folder with the app inside it (portable,
//      and how the app runs while it is being built)
//   3. installed: the page from the installer's "dashboard" folder; the data in the user's own app data folder
//      (Windows %APPDATA%\OSRS Dashboard, Mac ~/Library/Application Support/OSRS Dashboard). A root.txt there holding
//      a folder path uses that dashboard folder instead (e.g. the one the PowerShell version used; never run both
//      at once). On the first start the reference lists (collection log layout, task lists...) are copied in.

use std::fs;
use std::path::{Path, PathBuf};

pub struct Layout {
    pub pages: PathBuf,
    pub root: PathBuf,
    // The installer's pictures, used when the data folder has no copy of a picture
    pub bundled_icons: Option<PathBuf>,
}

fn has_page(d: &Path) -> bool {
    d.join("index.html").is_file() && d.join("app.js").is_file()
}

// The installer's "dashboard" folder: next to the app on Windows, in Contents/Resources on a Mac
fn bundled() -> Option<PathBuf> {
    let exe_dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    [exe_dir.join("dashboard"), exe_dir.join("..").join("Resources").join("dashboard")].into_iter().find(|d| has_page(d))
}

pub fn user_data_dir() -> PathBuf {
    let home = crate::refresh::home_dir();
    if cfg!(windows) {
        std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| home.join("AppData").join("Roaming")).join("OSRS Dashboard")
    } else if cfg!(target_os = "macos") {
        home.join("Library").join("Application Support").join("OSRS Dashboard")
    } else {
        std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".local").join("share")).join("osrs-dashboard")
    }
}

fn with_pages(root: PathBuf) -> Layout {
    if has_page(&root) {
        return Layout { pages: root.clone(), root, bundled_icons: None };
    }
    match bundled() {
        Some(b) => Layout { bundled_icons: Some(b.join("icons")), pages: b, root },
        None => Layout { pages: root.clone(), root, bundled_icons: None },
    }
}

pub fn find(args: &[String]) -> Layout {
    if let Some(i) = args.iter().position(|a| a == "--root") {
        if let Some(p) = args.get(i + 1) {
            return with_pages(PathBuf::from(p));
        }
    }
    if let Some(p) = std::env::var_os("OSRS_DASHBOARD_ROOT") {
        return with_pages(PathBuf::from(p));
    }
    let mut dir = std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.to_path_buf()));
    while let Some(d) = dir {
        if has_page(&d) {
            return Layout { pages: d.clone(), root: d, bundled_icons: None };
        }
        dir = d.parent().map(|p| p.to_path_buf());
    }
    if let Some(b) = bundled() {
        let home = user_data_dir();
        let _ = fs::create_dir_all(&home);
        let root = fs::read_to_string(home.join("root.txt"))
            .ok()
            .map(|t| PathBuf::from(t.trim().trim_start_matches('\u{feff}')))
            .filter(|p| p.is_dir())
            .unwrap_or(home);
        first_start(&b.join("starter"), &root);
        return Layout { bundled_icons: Some(b.join("icons")), pages: b, root };
    }
    let cwd = std::env::current_dir().unwrap_or_default();
    Layout { pages: cwd.clone(), root: cwd, bundled_icons: None }
}

// The reference lists a new install needs; a file that is already there is never replaced
fn first_start(starter: &Path, root: &Path) {
    fn copy_missing(src: &Path, dst: &Path) {
        let Ok(rd) = fs::read_dir(src) else { return };
        for e in rd.flatten() {
            let (s, d) = (e.path(), dst.join(e.file_name()));
            if s.is_dir() {
                copy_missing(&s, &d);
            } else if !d.exists() {
                let _ = fs::create_dir_all(dst);
                let _ = fs::copy(&s, &d);
            }
        }
    }
    copy_missing(starter, root);
}
