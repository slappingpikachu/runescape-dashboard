// Command-line use without a window, for the tests in tools\ (parity-test.ps1, test-plugin-files.ps1 -Impl app):
//   --root <folder> --cli GET|POST <path> [body|@file] [--out <file>]   one request; answer to stdout (or the file)
//   --root <folder> --step progress|lootgaps|clog|bank|kills [time]  one Refresh step; its message to stdout
//   --plugin-dir <player>                                          the plugin folder used for that player
//   --same <file A> <file B>                                       0 = same data (JSON / JSONL compared as data)

use crate::icons::Icons;
use crate::net::Web;
use crate::refresh::{self, Ctx};
use crate::server::Dashboard;
use serde_json::Value;
use std::io::Write;
use crate::layout::Layout;
use std::path::{Path, PathBuf};

fn arg(args: &[String], name: &str, n: usize) -> Option<String> {
    let i = args.iter().position(|a| a == name)?;
    args.get(i + n).cloned()
}

fn out(args: &[String], body: &[u8]) {
    match arg(args, "--out", 1) {
        Some(f) => {
            let _ = std::fs::write(f, body);
        }
        None => {
            let _ = std::io::stdout().write_all(body);
        }
    }
}

// None = not a command-line run (open the window)
pub fn run(args: &[String], layout: &Layout) -> Option<i32> {
    let root = layout.root.as_path();
    if args.iter().any(|a| a == "--cli") {
        let dash = Dashboard::new(layout);
        let method = arg(args, "--cli", 1).unwrap_or_else(|| "GET".into());
        let path = arg(args, "--cli", 2).unwrap_or_else(|| "/".into());
        // A body starting with @ is read from that file (an export file for POST /api/import)
        let body = arg(args, "--cli", 3).filter(|b| b != "--out").unwrap_or_default();
        let body = match body.strip_prefix('@') {
            Some(f) => std::fs::read(f).unwrap_or_default(),
            None => body.into_bytes(),
        };
        let req = tauri::http::Request::builder()
            .method(method.as_str())
            .uri(format!("http://dash.localhost{path}"))
            .body(body)
            .unwrap();
        let res = dash.handle(&req);
        if arg(args, "--out", 1).is_none() {
            eprintln!("{}", res.status().as_u16());
        }
        out(args, res.body());
        return Some(if res.status().is_success() { 0 } else { 1 });
    }
    if let Some(step) = arg(args, "--step", 1) {
        let player = refresh::load_settings(root).player;
        let web = Web::new();
        let icons = Icons::new(root, layout.bundled_icons.clone());
        let ctx = Ctx { data: root.join("data"), plugin_dir: refresh::plugin_dir(&player), web: &web, icons: &icons };
        let r = match step.as_str() {
            "progress" => crate::plugin::update_progress(&ctx),
            "lootgaps" => crate::plugin::update_loot_gaps(&ctx),
            "clog" => crate::plugin::update_clog(&ctx),
            "bank" => crate::bank::update(&ctx),
            "kills" => crate::plugin::update_kills(&ctx, &arg(args, "--step", 2).unwrap_or_default()),
            _ => Err(format!("unknown step {step}")),
        };
        return Some(match r {
            Ok(m) => {
                println!("{m}");
                0
            }
            Err(e) => {
                println!("ERROR: {e}");
                1
            }
        });
    }
    if let Some(p) = arg(args, "--plugin-dir", 1) {
        println!("{}", refresh::plugin_dir(&p).display());
        return Some(0);
    }
    if let (Some(a), Some(b)) = (arg(args, "--same", 1), arg(args, "--same", 2)) {
        return Some(match same_files(&PathBuf::from(a), &PathBuf::from(b)) {
            Ok(()) => 0,
            Err(e) => {
                println!("{e}");
                1
            }
        });
    }
    None
}

// Two JSON (or JSON-lines) files hold the same data: same values, keys in any order, 1 == 1.0
fn same_files(a: &Path, b: &Path) -> Result<(), String> {
    let ta = crate::util::read_text(a).ok_or("A is missing")?;
    let tb = crate::util::read_text(b).ok_or("B is missing")?;
    if let (Ok(va), Ok(vb)) = (serde_json::from_str::<Value>(&ta), serde_json::from_str::<Value>(&tb)) {
        return same(&va, &vb, "$");
    }
    let la: Vec<&str> = ta.lines().filter(|l| !l.trim().is_empty()).collect();
    let lb: Vec<&str> = tb.lines().filter(|l| !l.trim().is_empty()).collect();
    if la.len() != lb.len() {
        return Err(format!("{} lines vs {}", la.len(), lb.len()));
    }
    for (i, (x, y)) in la.iter().zip(&lb).enumerate() {
        match (serde_json::from_str::<Value>(x), serde_json::from_str::<Value>(y)) {
            (Ok(vx), Ok(vy)) => same(&vx, &vy, &format!("line {}", i + 1))?,
            _ if x == y => {}
            _ => return Err(format!("line {} differs (not JSON)", i + 1)),
        }
    }
    Ok(())
}

fn same(a: &Value, b: &Value, at: &str) -> Result<(), String> {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            let (x, y) = (x.as_f64().unwrap_or(f64::NAN), y.as_f64().unwrap_or(f64::NAN));
            if x == y || (x - y).abs() <= 1e-12 * x.abs().max(y.abs()) {
                Ok(())
            } else {
                Err(format!("{at}: {x} vs {y}"))
            }
        }
        (Value::Array(x), Value::Array(y)) => {
            if x.len() != y.len() {
                return Err(format!("{at}: {} items vs {}", x.len(), y.len()));
            }
            for (i, (p, q)) in x.iter().zip(y).enumerate() {
                same(p, q, &format!("{at}[{i}]"))?;
            }
            Ok(())
        }
        (Value::Object(x), Value::Object(y)) => {
            for k in x.keys() {
                if !y.contains_key(k) {
                    return Err(format!("{at}.{k}: only in A"));
                }
            }
            for (k, q) in y {
                match x.get(k) {
                    Some(p) => same(p, q, &format!("{at}.{k}"))?,
                    None => return Err(format!("{at}.{k}: only in B")),
                }
            }
            Ok(())
        }
        _ if a == b => Ok(()),
        _ => {
            let s = |v: &Value| v.to_string().chars().take(80).collect::<String>();
            Err(format!("{at}: {} vs {}", s(a), s(b)))
        }
    }
}
