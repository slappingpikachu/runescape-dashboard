// Collection log helpers: every log item id, GE prices of the items you've obtained, wiki image files.
// data\clog\history.jsonl itself is written by plugin.rs (Update-PluginClog).
//
// Collection log files (moved here from clog.ps1 when the PowerShell version was retired):
// Collection log for the page. The items come only from the OSRS Data Sync RuneLite plugin
// (plugin.ps1 Update-PluginClog, on Refresh); no other plugin or site is used. Names, pictures and GE prices come
// from the OSRS Wiki.
// Dot-sourced by server.ps1; needs $DataDir, $Root, $Player, $Utf8 and Add-IconOutline.
//
// data\clog\history.jsonl   one line per change (new item or a higher count):
//                           {"t":ISO,"changed":"yyyy-MM-dd HH:mm:ss","total":n,"available":n,"src":"plugin",
//                            "items":{"<id>":[count,"<date first seen>"],...}}  (lines without src: saved Oct 24 - Nov 1, before the plugin)
// data\clog\items.json      id -> item name (OSRS Wiki, tools\fetch-clog-layout.ps1; new ids get their name from the wiki)
// data\clog\categories.json {"names":{page:"Page name"}, tab:{page:[ids]}} in collection log order (OSRS Wiki,
//                           tools\fetch-clog-layout.ps1; run it again when Jagex adds log items)
// data\clog\images.json     id -> OSRS Wiki image file, for icons\item\<id>.png

use crate::refresh::Ctx;
use crate::util::*;
use indexmap::{IndexMap, IndexSet};
use regex::Regex;
use serde_json::{json, Map, Value};
use std::sync::LazyLock;

pub const WIKI_API: &str = "https://oldschool.runescape.wiki/api.php";
pub const PRICES_URL: &str = "https://prices.runescape.wiki/api/v1/osrs/latest";

// A wiki "bucket" query URL
pub fn bucket_url(q: &str) -> String {
    format!("{WIKI_API}?action=bucket&format=json&query={}", escape_data(q))
}

// One GE price from the buy (high) and sell (low) side: normally their average. When the sides are more than 3
// times apart only one is used: the one closer to `r` (a recent price), else the one with the bigger weight.
pub fn ge_price(h: Option<f64>, l: Option<f64>, hw: Option<f64>, lw: Option<f64>, r: Option<f64>) -> Option<f64> {
    let set = |x: Option<f64>| x.map(|v| v != 0.0).unwrap_or(false);
    if !set(h) {
        return l;
    }
    if !set(l) {
        return h;
    }
    let (h, l) = (h.unwrap(), l.unwrap());
    if h.max(l) <= 3.0 * h.min(l) {
        return Some(((h + l) / 2.0).round_ties_even());
    }
    if let Some(r) = r.filter(|r| *r > 0.0) {
        return Some(if (h / r).ln().abs() < (l / r).ln().abs() { h } else { l });
    }
    // PowerShell's -gt with $null: $null sits between -1 and 0
    let higher = match (hw, lw) {
        (None, None) => false,
        (None, Some(b)) => b < 0.0,
        (Some(a), None) => a >= 0.0,
        (Some(a), Some(b)) => a > b,
    };
    Some(if higher { h } else { l })
}

// Every item id in the log (owned or not), in categories.json order
pub fn all_log_ids(ctx: &Ctx) -> Vec<String> {
    let Some(cats) = read_json(&ctx.clog_dir().join("categories.json")) else { return Vec::new() };
    let mut ids: IndexSet<String> = IndexSet::new();
    for (group, v) in props(Some(&cats)) {
        if group == "names" {
            continue;
        }
        for (_, list) in props(Some(&v)) {
            for id in ps_each(Some(&list)) {
                ids.insert(ps_string(Some(&id)));
            }
        }
    }
    ids.into_iter().collect()
}

static LOG_ITEMS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""items":\{(.*)\}"#).unwrap());
static LOG_COUNT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""(\d+)":\[(\d+)"#).unwrap());

// Collection log items you've obtained (count > 0 in the latest saved log)
pub fn logged_ids(ctx: &Ctx) -> Vec<String> {
    let Some(last) = last_line(&ctx.clog_dir().join("history.jsonl")) else { return Vec::new() };
    let items = LOG_ITEMS.captures(&last).map(|c| c[1].to_string()).unwrap_or_default();
    LOG_COUNT
        .captures_iter(&items)
        .filter(|c| c[2].parse::<i64>().unwrap_or(0) > 0)
        .map(|c| c[1].to_string())
        .collect()
}

// GE prices of the log items you've obtained; downloaded again only when the log changed (or there is no file)
// data\clog\prices.json  {"t":ISO,"prices":{"<id>":gp}}
pub fn update_prices(ctx: &Ctx, log_changed: bool, log_ids: &[String]) -> Res<String> {
    let f = ctx.clog_dir().join("prices.json");
    if f.is_file() && !log_changed {
        return Ok("prices stored".into());
    }
    let all = ctx.web.get_json(PRICES_URL)?;
    let data = prop(&all, "data").cloned().unwrap_or(Value::Null);
    let reset = read_json(&ctx.data.join("bank").join("prices-reset.json"));
    let refs = reset.as_ref().and_then(|r| prop(r, "prices")).cloned().unwrap_or(Value::Null);
    let mut prices = Map::new();
    for id in log_ids {
        let Some(p) = prop(&data, id).filter(|p| truthy(p)) else { continue };
        let g = ge_price(
            ps_f64(prop(p, "high")),
            ps_f64(prop(p, "low")),
            ps_f64(prop(p, "highTime")),
            ps_f64(prop(p, "lowTime")),
            ps_f64(prop(&refs, id)),
        );
        if let Some(g) = g.filter(|g| *g != 0.0) {
            prices.insert(id.clone(), json!(g.round_ties_even() as i64));
        }
    }
    let n = prices.len();
    write_text(&f, &ps_json(&json!({ "t": iso(now()), "prices": Value::Object(prices) }))).err_text()?;
    Ok(format!("prices updated ({n} items)"))
}

// Wiki image files for item ids not looked up before (40 per request). data\clog\images.json: id -> file
pub fn update_images(ctx: &Ctx, ids: &[String]) -> Res<()> {
    let f = ctx.clog_dir().join("images.json");
    let mut map: IndexMap<String, Value> = IndexMap::new();
    if let Some(Value::Object(o)) = read_json(&f) {
        for (k, v) in o {
            map.insert(k, v);
        }
    }
    let mut todo: IndexSet<String> = IndexSet::new();
    for id in ids {
        if !map.contains_key(id) {
            todo.insert(id.clone());
        }
    }
    let todo: Vec<String> = todo.into_iter().collect();
    if todo.is_empty() {
        return Ok(());
    }
    for batch in todo.chunks(40) {
        let or = batch.iter().map(|id| format!("{{'item_id','{id}'}}")).collect::<Vec<_>>().join(",");
        let q = format!("bucket('infobox_item').select('item_id','image').where(bucket.Or({or})).limit(500).run()");
        let res = ctx.web.get_json(&bucket_url(&q))?;
        for row in ps_each(prop(&res, "bucket")) {
            let first = ps_array(prop(&row, "image")).into_iter().next().unwrap_or(Value::Null);
            let file = strip_file(&ps_string(Some(&first)));
            if file.is_empty() {
                continue;
            }
            for id in ps_array(prop(&row, "item_id")) {
                let id = ps_string(Some(&id));
                if batch.contains(&id) && !map.contains_key(&id) {
                    map.insert(id, Value::String(file.clone()));
                }
            }
        }
        pause(400);
    }
    // Not found by id on the wiki: try "<item name>.png"
    if let Some(names) = read_json(&ctx.clog_dir().join("items.json")) {
        let known = prop(&names, "items").cloned().unwrap_or(Value::Null);
        for id in &todo {
            if !map.contains_key(id) && opt_truthy(prop(&known, id)) {
                map.insert(id.clone(), Value::String(format!("{}.png", ps_string(prop(&known, id)))));
            }
        }
    }
    write_text(&f, &ps_json(&Value::Object(map.into_iter().collect()))).err_text()
}

// "File:Abyssal whip.png" -> "Abyssal whip.png" (PowerShell's -replace '^File:', '' ignores case)
pub fn strip_file(s: &str) -> String {
    match s.get(..5) {
        Some(p) if p.eq_ignore_ascii_case("file:") => s[5..].to_string(),
        _ => s.to_string(),
    }
}
