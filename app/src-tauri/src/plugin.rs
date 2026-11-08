// JSON export files from RuneLite ("OSRS Data Sync" format, plugin.ps1), turned into the dashboard's
// data files on Refresh: quests/diaries/combat achievements, the collection log, bank containers, kill totals,
// monster pictures, and the drop log's gaps (kills done without the plugin).

use crate::bank::update_items;
use crate::clog;
use crate::refresh::Ctx;
use crate::util::*;
use chrono::{DateTime, TimeZone, Utc};
use indexmap::{IndexMap, IndexSet};
use regex::Regex;
use serde_json::{json, Map, Value};
use std::sync::LazyLock;

type Pairs = Vec<(i64, i64)>;

// ---- Quests, diaries, combat achievements (progress.json) -> data\progress\latest.json + history.jsonl ----
static NO_STAMP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""timestamp":"[^"]*","#).unwrap());

pub fn update_progress(ctx: &Ctx) -> Res<String> {
    let file = ctx.plugin_dir.join("progress.json");
    if !file.exists() {
        return Ok("Progress: no progress.json yet (log in with OSRS Data Sync on)".into());
    }
    let p: Value = serde_json::from_str(trim(&read_text(&file).unwrap_or_default())).err_text()?;
    if !opt_truthy(prop(&p, "quests")) {
        return Ok("Progress: progress.json has no quests yet".into());
    }
    if crate::sync::is_stale(&ctx.data, "progress", &crate::sync::updated_in(&read_text(&file).unwrap_or_default())) {
        return Ok("Progress: skipped (older than the data imported from your other device; log in to RuneLite here to update it)".into());
    }
    let dir = ctx.data.join("progress");
    ensure_dir(&dir);
    let info = read_json(&dir.join("diary-tasks.json"));

    let mut quests = Map::new();
    for (name, v) in props(prop(&p, "quests")) {
        quests.insert(name, json!(ps_long(Some(&v))));
    }
    let mut diaries = Map::new();
    for (region, v) in props(prop(&p, "diaries")) {
        let mut tiers = Map::new();
        for tier in ["Easy", "Medium", "Hard", "Elite"] {
            let n = info
                .as_ref()
                .map(|i| {
                    let tasks = prop(i, &region).and_then(|r| prop(r, tier)).and_then(|t| prop(t, "tasks"));
                    ps_array(tasks).iter().filter(|t| truthy(t)).count()
                })
                .unwrap_or(0);
            let done = prop(&v, tier).map(truthy).unwrap_or(false);
            // Per-task flags from the plugin ("1"/"0" in diary-tasks.json order); older plugins have none
            let flags = ps_string(prop(&p, "diaryTasks").and_then(|d| prop(d, &region)).and_then(|r| prop(r, tier)));
            let value = if done {
                json!([n, n, "1".repeat(n)])
            } else if n > 0 && flags.len() == n && flags.bytes().all(|b| b == b'0' || b == b'1') {
                json!([flags.bytes().filter(|&b| b == b'1').count(), n, flags])
            } else {
                json!([null, n, ""])
            };
            tiers.insert(tier.into(), value);
        }
        diaries.insert(region, Value::Object(tiers));
    }
    // `$null | ForEach-Object` runs once: no "ca" at all gives [0], like the PowerShell version
    let mut ca: Vec<i64> = match prop(&p, "ca") {
        None | Some(Value::Null) => vec![0],
        v => ps_each(v).iter().map(|x| ps_long(Some(x))).collect(),
    };
    ca.sort();
    let finished = quests.values().filter(|q| q.as_i64() == Some(2)).count();
    let (nq, nca) = (quests.len(), ca.len());
    let slim = ps_json(&json!({
        "v": 3, "src": "plugin", "timestamp": ps_string(prop(&p, "updated")),
        "quests": Value::Object(quests), "diaries": Value::Object(diaries), "ca": ca
    }));
    let latest = dir.join("latest.json");
    let prev = read_text(&latest).unwrap_or_default();
    if NO_STAMP.replace_all(&prev, "") == NO_STAMP.replace_all(&slim, "") {
        if prev != slim {
            write_text(&latest, &slim).err_text()?;
        }
        return Ok("Progress: no change".into());
    }
    write_text(&latest, &slim).err_text()?;
    append_text(&dir.join("history.jsonl"), &format!("{slim}\n")).err_text()?;
    Ok(format!("Progress: saved ({finished}/{nq} quests, {nca} combat tasks)"))
}

// ---- Collection log (clog.json) -> data\clog\history.jsonl ----
// Items are merged with the previous line (higher count wins); drops of log items (loot.jsonl after the lootT
// marker, loot-gaps.jsonl after gapN lines) count straight into the log.
static LINE_T: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""t":"([^"]+)""#).unwrap());

fn stamp(t: DateTime<Utc>) -> String {
    t.format("%Y-%m-%d %H:%M:%S").to_string()
}

pub fn update_clog(ctx: &Ctx) -> Res<String> {
    let file = ctx.plugin_dir.join("clog.json");
    if !file.exists() {
        return Ok("Collection log: no clog.json yet (open the log in game and press Search once)".into());
    }
    let c: Value = serde_json::from_str(trim(&read_text(&file).unwrap_or_default())).err_text()?;
    let dir = ctx.clog_dir();
    ensure_dir(&dir);
    let hist = dir.join("history.jsonl");
    let prev: Option<Value> = match last_line(&hist) {
        Some(l) => Some(serde_json::from_str(trim(&l)).err_text()?),
        None => None,
    };
    let now_s = stamp(now());
    let mut items: IndexMap<String, (i64, String)> = IndexMap::new();
    if let Some(p) = &prev {
        for (id, v) in props(prop(p, "items")) {
            items.insert(id, (ps_long(v.get(0)), ps_string(v.get(1))));
        }
    }
    let log_ids = clog::all_log_ids(ctx);
    let log_set: IndexSet<String> = log_ids.iter().cloned().collect();

    let mut loot_t = match prev.as_ref().and_then(|p| prop(p, "lootT")).filter(|v| truthy(v)) {
        Some(v) => ps_string(Some(v)),
        None => ps_string(prop(&c, "updated")),
    };
    let mut drop_add: IndexMap<String, i64> = IndexMap::new();
    let mut drop_date: IndexMap<String, String> = IndexMap::new();
    let loot_file = ctx.plugin_dir.join("loot.jsonl");
    if !loot_t.is_empty() && loot_file.exists() {
        let marker = parse_time_or_err(&loot_t)?;
        let lines = read_lines(&loot_file);
        let mut newest: Option<String> = None;
        for line in lines.iter().rev() {
            // newest first, stop at the marker
            let Some(m) = LINE_T.captures(line) else { continue };
            let t_text = m[1].to_string();
            let t = parse_time_or_err(&t_text)?;
            if t <= marker {
                break;
            }
            // A line still being written (or a damaged one) is skipped
            let Ok(entry) = serde_json::from_str::<Value>(trim(line)) else { continue };
            if newest.is_none() {
                newest = Some(t_text);
            }
            for d in ps_array(prop(&entry, "items")) {
                let id = ps_string(d.get(0));
                if !log_set.contains(&id) {
                    continue;
                }
                *drop_add.entry(id.clone()).or_insert(0) += ps_long(d.get(1));
                drop_date.insert(id, stamp(t)); // ends on the earliest drop
            }
        }
        if let Some(n) = newest {
            loot_t = n;
        }
    }
    // Log items among the drops of kills done without the plugin (loot-gaps.jsonl)
    let mut gap_n = match prev.as_ref().and_then(|p| prop(p, "gapN")).filter(|v| !v.is_null()) {
        Some(v) => ps_long(Some(v)),
        None => 0,
    };
    let gap_file = ctx.loot_gap_file();
    if gap_file.exists() {
        let gl: Vec<String> = read_lines(&gap_file).into_iter().filter(|l| !trim(l).is_empty()).collect();
        for line in gl.iter().skip(gap_n.max(0) as usize) {
            let Ok(entry) = serde_json::from_str::<Value>(trim(line)) else { continue };
            if !opt_truthy(prop(&entry, "items")) {
                continue;
            }
            let t = parse_time_or_err(&ps_string(prop(&entry, "t")))?;
            for d in ps_array(prop(&entry, "items")) {
                let id = ps_string(d.get(0));
                if !log_set.contains(&id) {
                    continue;
                }
                *drop_add.entry(id.clone()).or_insert(0) += ps_long(d.get(1));
                drop_date.entry(id).or_insert_with(|| stamp(t));
            }
        }
        gap_n = gl.len() as i64;
    }
    // Count = the higher of the plugin's own count and the last saved count plus those drops
    let mut plugin: IndexMap<String, i64> = IndexMap::new();
    for (id, v) in props(prop(&c, "items")) {
        let q = ps_long(Some(&v));
        if q > 0 {
            plugin.insert(id, q);
        }
    }
    // New items from the game's "New item added to your collection log" message (newByName): name -> log id via
    // the saved names (a name shared by several log ids is skipped), at least 1, dated at the message
    let mut new_date: IndexMap<String, String> = IndexMap::new();
    let new_by_name = props(prop(&c, "newByName"));
    if !new_by_name.is_empty() {
        let name_map = read_json(&dir.join("items.json")).and_then(|v| prop(&v, "items").cloned()).unwrap_or(Value::Null);
        let mut by_name: IndexMap<String, String> = IndexMap::new();
        for id in &log_set {
            let n = ps_array(prop(&name_map, id)).into_iter().next().map(|v| ps_string(Some(&v))).unwrap_or_default();
            if n.is_empty() {
                continue;
            }
            let k = n.to_lowercase();
            let v = match by_name.get(&k) {
                Some(x) if x != id => String::new(),
                _ => id.clone(),
            };
            by_name.insert(k, v);
        }
        for (name, t) in new_by_name {
            let Some(id) = by_name.get(&name.to_lowercase()).filter(|x| !x.is_empty()).cloned() else { continue };
            let e = plugin.entry(id.clone()).or_insert(0);
            if *e < 1 {
                *e = 1;
            }
            new_date.insert(id, parse_time_or_err(&ps_string(Some(&t))).map(stamp).unwrap_or_else(|_| now_s.clone()));
        }
    }
    let mut ids: IndexSet<String> = plugin.keys().cloned().collect();
    ids.extend(drop_add.keys().cloned());
    let mut changes = 0;
    for id in &ids {
        let had = items.get(id).map(|x| x.0).unwrap_or(0);
        let pl = plugin.get(id).copied().unwrap_or(0);
        // The first time the drops come on top of the plugin's count (they all came after its clog.json was written)
        let base = if prev.is_some() { had } else { pl };
        let q = pl.max(base + drop_add.get(id).copied().unwrap_or(0));
        if q <= had {
            continue;
        }
        let date = match items.get(id) {
            Some(x) => x.1.clone(),
            None => new_date.get(id).or_else(|| drop_date.get(id)).cloned().unwrap_or_else(|| now_s.clone()),
        };
        items.insert(id.clone(), (q, date));
        changes += 1;
    }
    let prev_available = prev.as_ref().map(|p| ps_long(prop(p, "available"))).unwrap_or(0);
    let available = (log_ids.len() as i64).max(prev_available);
    let mut status = "no change".to_string();
    if changes > 0 || prev.is_none() {
        let list: Map<String, Value> = items.iter().map(|(k, (q, d))| (k.clone(), json!([q, d]))).collect();
        let line = ps_json(&json!({
            "t": iso(now()), "changed": now_s, "src": "plugin", "total": items.len(), "available": available,
            "lootT": loot_t, "gapN": gap_n, "items": Value::Object(list)
        }));
        append_text(&hist, &format!("{line}\n")).err_text()?;
        status = format!("saved ({changes} item{} new or increased)", if changes != 1 { "s" } else { "" });
    }
    // Names for ids the saved list doesn't know (new content): the wiki, via the bank's name lookup
    let names_file = dir.join("items.json");
    let mut names: Map<String, Value> = read_json(&names_file)
        .and_then(|v| prop(&v, "items").cloned())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    let unknown: Vec<String> = items.keys().filter(|id| !names.contains_key(*id)).cloned().collect();
    if !unknown.is_empty() {
        let r = update_items(ctx, &unknown).and_then(|_| {
            let bank_names = read_json(&ctx.data.join("bank").join("items.json")).unwrap_or(Value::Null);
            for id in &unknown {
                if let Some(n) = prop(&bank_names, id).filter(|n| truthy(n)) {
                    names.insert(id.clone(), ps_array(Some(n)).into_iter().next().unwrap_or(Value::Null));
                }
            }
            write_text(&names_file, &ps_json(&json!({ "items": Value::Object(names.clone()) }))).err_text()
        });
        if let Err(e) = r {
            eprintln!("Collection log names failed: {e}");
        }
    }
    let mut all: Vec<String> = items.keys().cloned().collect();
    all.extend(log_ids.iter().cloned());
    clog::update_images(ctx, &all)?;
    // Prices only for the log items you've obtained
    let obtained: Vec<String> = items.iter().filter(|(_, x)| x.0 > 0).map(|(k, _)| k.clone()).collect();
    let prices = clog::update_prices(ctx, changes > 0, &obtained).unwrap_or_else(|e| format!("prices unavailable: {e}"));
    Ok(format!("Collection log (OSRS Data Sync): {status} ({}/{available}) - {prices}", items.len()))
}

// ---- Bank + equipment + inventory (containers.json), for bank.rs ----
pub struct Containers {
    pub bank: Pairs,
    pub equipment: Pairs,
    pub inventory: Pairs,
    pub rune_pouch: Option<Pairs>,
    pub inv_layout: Vec<(i64, i64, i64)>, // [slot, id, qty]
    pub ge: Option<String>,               // offers as the JSON text of a bank history line
    pub bank_at: i64,
    pub updated: DateTime<Utc>,
}

// None when there is no file or the bank was never opened with the plugin on ("bank": [] = really empty)
pub fn containers(ctx: &Ctx) -> Res<Option<Containers>> {
    let file = ctx.plugin_dir.join("containers.json");
    if !file.exists() {
        return Ok(None);
    }
    let c: Value = serde_json::from_str(trim(&read_text(&file).unwrap_or_default())).err_text()?;
    if prop(&c, "bank").map(|b| b.is_null()).unwrap_or(true) {
        return Ok(None);
    }
    let conv = |v: Option<&Value>| -> Pairs {
        ps_array(v).iter().filter(|p| truthy(p)).map(|p| (ps_long(p.get(0)), ps_long(p.get(1)))).collect()
    };
    let inv_layout = ps_array(prop(&c, "inventory"))
        .iter()
        .filter(|p| truthy(p) && p.as_array().map(|a| a.len() >= 3).unwrap_or(false))
        .map(|p| (ps_long(p.get(2)), ps_long(p.get(0)), ps_long(p.get(1))))
        .collect();
    let ge = prop(&c, "ge").map(|list| {
        let offers: Vec<String> = ps_array(Some(list))
            .iter()
            .filter(|o| truthy(o))
            .map(|o| {
                format!(
                    "{{\"item\":[{},{}],\"done\":{},\"price\":{},\"spent\":{},\"state\":\"{}\"}}",
                    ps_long(prop(o, "id")),
                    ps_long(prop(o, "total")),
                    ps_long(prop(o, "done")),
                    ps_long(prop(o, "price")),
                    ps_long(prop(o, "spent")),
                    ps_string(prop(o, "state"))
                )
            })
            .collect();
        format!("[{}]", offers.join(","))
    });
    Ok(Some(Containers {
        ge,
        bank: conv(prop(&c, "bank")),
        equipment: conv(prop(&c, "equipment")),
        inventory: conv(prop(&c, "inventory")),
        rune_pouch: prop(&c, "runePouch").map(|p| conv(Some(p))),
        inv_layout,
        bank_at: ps_long(prop(&c, "bankAt")),
        updated: parse_time_or_err(&ps_string(prop(&c, "updated")))?,
    }))
}

// ---- Monster pictures for the Kills & loot list ----
// icons\npc\<slug>.png from the wiki (infobox_monster, else infobox_npc; "<Name>.png" if there is one), shrunk to fit
// 64 px and outlined. data\plugin\npc-images.json remembers name -> wiki file ("" = no picture).
static NOT_SLUG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^a-z0-9]+").unwrap());
pub fn npc_slug(name: &str) -> String {
    NOT_SLUG.replace_all(&name.to_lowercase(), "-").trim_matches('-').to_string()
}

fn update_npc_icons(ctx: &Ctx, names: &[String]) -> Res<String> {
    let map_file = ctx.plugin_data().join("npc-images.json");
    let mut map: Map<String, Value> = match read_text(&map_file) {
        Some(t) => serde_json::from_str::<Value>(trim(&t)).err_text()?.as_object().cloned().unwrap_or_default(),
        None => Map::new(),
    };
    let todo = sort_unique(names.iter().filter(|n| !n.is_empty() && !map.contains_key(*n)).cloned().collect());
    for (bucket, field) in [("infobox_monster", "name"), ("infobox_npc", "page_name")] {
        let left: Vec<String> = todo.iter().filter(|n| !opt_truthy(map.get(*n))).cloned().collect();
        for batch in left.chunks(30) {
            let or = batch.iter().map(|n| format!("{{'{field}','{}'}}", n.replace('\'', "\\'"))).collect::<Vec<_>>().join(",");
            let q = format!("bucket('{bucket}').select('{field}','image').where(bucket.Or({or})).limit(1000).run()");
            let res = ctx.web.get_json(&clog::bucket_url(&q)).ok();
            let mut found: IndexMap<String, String> = IndexMap::new();
            for row in ps_array(res.as_ref().and_then(|r| prop(r, "bucket"))) {
                let n = ps_string(prop(&row, field));
                for img in ps_array(prop(&row, "image")) {
                    let file = clog::strip_file(&ps_string(Some(&img)));
                    if file.is_empty() {
                        continue;
                    }
                    if file.to_lowercase() == format!("{n}.png").to_lowercase() {
                        found.insert(n.clone(), file);
                    } else if found.get(&n).map(|f| f.is_empty()).unwrap_or(true) {
                        found.insert(n.clone(), file);
                    }
                }
            }
            for n in batch {
                if let Some(f) = found.get(n).filter(|f| !f.is_empty()) {
                    map.insert(n.clone(), Value::String(f.clone()));
                }
            }
            pause(300);
        }
    }
    for n in &todo {
        if !map.contains_key(n) {
            map.insert(n.clone(), Value::String(String::new()));
        }
    }
    if !todo.is_empty() {
        ensure_dir(&ctx.plugin_data());
        write_text(&map_file, &ps_json(&Value::Object(map.clone()))).err_text()?;
    }
    // Download the pictures not saved yet (at most 80 per Refresh)
    let dir = ctx.icons.dir.join("npc");
    ensure_dir(&dir);
    let (mut saved, mut tried) = (0, 0);
    for n in names {
        let Some(file) = map.get(n).filter(|f| truthy(f)).map(|f| ps_string(Some(f))) else { continue };
        let slug = npc_slug(n);
        let out = dir.join(format!("{slug}.png"));
        if ctx.icons.has("npc", &format!("{slug}.png")) || ctx.icons.known_missing(&format!("npc/{slug}")) {
            continue;
        }
        tried += 1;
        if tried > 80 {
            break;
        }
        let got = ctx.web.fetch(&format!("{}?width=64", crate::icons::wiki_file_url(&file)), crate::net::UA);
        let r = match got.body.as_ref().filter(|_| (200..300).contains(&got.status)) {
            Some(b) => crate::icons::shrink_outline(b).and_then(|png| std::fs::write(&out, png).err_text()),
            None => Err(format!("The remote server returned an error: ({}).", got.status)),
        };
        match r {
            Ok(()) => saved += 1,
            Err(e) => {
                eprintln!("Monster picture failed for {n}: {e}");
                ctx.icons.add_missing(&format!("npc/{slug}"), got.status);
            }
        }
    }
    let known = map.values().filter(|v| truthy(v)).count();
    Ok(format!("monster pictures: {saved} saved, {known} known"))
}

// ---- Kill history for the Recent activity feed: data\plugin\kills-history.jsonl {"t", "k": {"TYPE|name": kills}} ----
static KILL_HEAD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"^\{"t":"[^"]*","k":"#).unwrap());

pub fn update_kills(ctx: &Ctx, time: &str) -> Res<String> {
    let file = ctx.plugin_dir.join("killcounts.json");
    if !file.exists() {
        return Ok("Plugin kills: no killcounts.json yet (log in with the plugin on)".into());
    }
    let kc: Value = serde_json::from_str(trim(&read_text(&file).unwrap_or_default())).err_text()?;
    let tracker = prop(&kc, "lootTracker").cloned().unwrap_or(Value::Null);
    let mut k = Map::new();
    let mut ids: IndexSet<String> = IndexSet::new();
    for (ty, sources) in props(Some(&tracker)) {
        for (name, src) in props(Some(&sources)) {
            k.insert(format!("{ty}|{name}"), json!(ps_long(prop(&src, "kills"))));
            if opt_truthy(prop(&src, "drops")) {
                for (id, _) in props(prop(&src, "drops")) {
                    ids.insert(id);
                }
            }
        }
    }
    let ids: Vec<String> = ids.into_iter().collect();
    // Names (and wiki pictures) for dropped items, looked up once per new id
    let mut names = if ids.is_empty() {
        "no drops listed".to_string()
    } else {
        update_items(ctx, &ids).unwrap_or_else(|e| format!("names failed: {e}"))
    };
    // Their pictures, at most 300 per Refresh
    let missing: Vec<&String> = ids.iter().filter(|id| !ctx.icons.has("item", &format!("{id}.png"))).take(300).collect();
    let mut got_icons = 0;
    for id in &missing {
        if ctx.icons.get_item(ctx.web, &ctx.data, id).is_some() {
            got_icons += 1;
        }
    }
    if !missing.is_empty() {
        names.push_str(&format!("; drop icons saved: {got_icons} of {}", missing.len()));
    }
    // Pictures of the monsters and pickpocket targets (chests / clues keep their item picture)
    let mut npc_names: Vec<String> = Vec::new();
    for tn in ["NPC", "PICKPOCKET"] {
        if opt_truthy(prop(&tracker, tn)) {
            npc_names.extend(props(prop(&tracker, tn)).into_iter().map(|(n, _)| n));
        }
    }
    if !npc_names.is_empty() {
        let r = update_npc_icons(ctx, &npc_names).unwrap_or_else(|e| format!("monster pictures failed: {e}"));
        names.push_str(&format!("; {r}"));
    }
    if k.is_empty() {
        return Ok(format!("Plugin kills: Loot Tracker has nothing yet; {names}"));
    }
    if crate::sync::is_stale(&ctx.data, "killcounts", &crate::sync::updated_in(&read_text(&file).unwrap_or_default())) {
        return Ok(format!("Plugin kills: skipped (older than the data imported from your other device); {names}"));
    }
    let json = ps_json(&Value::Object(k.clone()));
    ensure_dir(&ctx.plugin_data());
    let hist = ctx.plugin_data().join("kills-history.jsonl");
    if let Some(last) = last_line(&hist) {
        let body = KILL_HEAD.replace(&last, "");
        let body = body.strip_suffix('}').unwrap_or(&body);
        if body == json {
            return Ok(format!("Plugin kills: no new kills; {names}"));
        }
    }
    append_text(&hist, &format!("{{\"t\":\"{time}\",\"k\":{json}}}\n")).err_text()?;
    Ok(format!("Plugin kills: saved ({} sources); {names}", k.len()))
}

// ---- Drop log gaps: kills + drops the Loot Tracker totals have but loot.jsonl doesn't (played without the plugin) ----
// data\plugin\loot-gaps.jsonl lines (loot.jsonl shape + "kills" and "gap": true) and data\plugin\loot-base.json
// {"t": killcounts.json "updated", "k": {"TYPE|name": {"drops": {id: q}, "kills": n}}} = accounted for up to t.
#[derive(Clone, Default)]
struct Totals {
    kills: i64,
    drops: IndexMap<String, i64>,
}
struct Source {
    ty: String,
    name: String,
    last: i64,
    totals: Totals,
}
struct LiveLine {
    t: DateTime<Utc>,
    key: String,
    items: Value,
}

fn drops_of(v: Option<&Value>) -> IndexMap<String, i64> {
    props(v).into_iter().map(|(k, x)| (k, ps_long(Some(&x)))).collect()
}

fn live_in(live: &[LiveLine], from: DateTime<Utc>, to: DateTime<Utc>) -> IndexMap<String, Totals> {
    let mut m: IndexMap<String, Totals> = IndexMap::new();
    for x in live {
        if x.t <= from || x.t > to {
            continue;
        }
        let e = m.entry(x.key.clone()).or_default();
        e.kills += 1;
        for it in ps_array(Some(&x.items)) {
            if truthy(&it) && it.as_array().map(|a| a.len() >= 2).unwrap_or(false) {
                *e.drops.entry(ps_string(it.get(0))).or_insert(0) += ps_long(it.get(1));
            }
        }
    }
    m
}

fn gap_line(lines: &mut Vec<(String, i64)>, ty: &str, name: &str, last: i64, from: DateTime<Utc>, to: DateTime<Utc>, kills: i64, items: Value) {
    // Dated at the source's last kill when that falls in the window, else at the window's end
    let mut at = if last > 0 { Utc.timestamp_millis_opt(last).single().unwrap_or(to) } else { to };
    if at <= from || at > to {
        at = to;
    }
    // from / to: the window, so kills logged on another device in it can come off this gap (sync.rs gap_fixed)
    let o = json!({"t": iso_ms(at), "source": name, "type": ty, "kills": kills, "gap": true, "from": iso_ms(from), "to": iso_ms(to), "items": items});
    lines.push((ps_json(&o), kills));
}

fn base_json(t: &Totals) -> Value {
    json!({"drops": Value::Object(t.drops.iter().map(|(k, v)| (k.clone(), json!(v))).collect()), "kills": t.kills})
}

pub fn update_loot_gaps(ctx: &Ctx) -> Res<String> {
    let kc_file = ctx.plugin_dir.join("killcounts.json");
    if !kc_file.exists() {
        return Ok("Drop log gaps: no killcounts.json yet".into());
    }
    let text = read_text(&kc_file).unwrap_or_default();
    let text = trim(&text);
    if !(text.starts_with('{') && text.ends_with('}')) {
        return Ok("Drop log gaps: killcounts.json cut off; skipped".into());
    }
    let kc: Value = serde_json::from_str(text).err_text()?;
    if !opt_truthy(prop(&kc, "updated")) || !opt_truthy(prop(&kc, "lootTracker")) {
        return Ok("Drop log gaps: Loot Tracker has nothing yet".into());
    }
    let u = parse_time_or_err(&ps_string(prop(&kc, "updated")))?;

    // Current totals per source
    let mut cur: IndexMap<String, Source> = IndexMap::new();
    for (ty, sources) in props(prop(&kc, "lootTracker")) {
        for (name, src) in props(Some(&sources)) {
            let totals = Totals { kills: ps_long(prop(&src, "kills")), drops: drops_of(prop(&src, "drops")) };
            cur.insert(
                format!("{ty}|{name}"),
                Source { ty: ty.clone(), name: name.clone(), last: ps_long(prop(&src, "last")), totals },
            );
        }
    }
    // The live drop log: whole lines only, parsed; a bad line is skipped
    let mut live: Vec<LiveLine> = Vec::new();
    for line in read_lines(&ctx.plugin_dir.join("loot.jsonl")) {
        let l = trim(&line);
        if !(l.starts_with(r#"{"t":""#) && l.ends_with('}')) {
            continue;
        }
        let Ok(o) = serde_json::from_str::<Value>(l) else { continue };
        let Some(t) = parse_time(&ps_string(prop(&o, "t"))) else { continue };
        let key = format!("{}|{}", ps_string(prop(&o, "type")), ps_string(prop(&o, "source")));
        live.push(LiveLine { t, key, items: prop(&o, "items").cloned().unwrap_or(Value::Null) });
    }
    let mut lines: Vec<(String, i64)> = Vec::new();
    let mut base: IndexMap<String, Totals> = IndexMap::new();
    let base_file = ctx.plugin_data().join("loot-base.json");
    let kh_file = ctx.plugin_data().join("kills-history.jsonl");

    if !base_file.exists() {
        // First run: kills-history windows since the drop log began (kills only; drops weren't saved then)
        let mut acc: IndexMap<String, i64> = IndexMap::new();
        let mut kh: Vec<(DateTime<Utc>, IndexMap<String, i64>)> = Vec::new();
        if !live.is_empty() && kh_file.exists() {
            for l in read_lines(&kh_file) {
                if trim(&l).is_empty() {
                    continue;
                }
                let Ok(o) = serde_json::from_str::<Value>(trim(&l)) else { continue };
                let Some(t) = parse_time(&ps_string(prop(&o, "t"))) else { continue };
                kh.push((t, drops_of(prop(&o, "k"))));
            }
        }
        if !kh.is_empty() {
            let log_start = live.iter().map(|x| x.t).min().unwrap();
            let mut s = 0;
            for (i, p) in kh.iter().enumerate() {
                if p.0 <= log_start {
                    s = i;
                }
            }
            let mut points: Vec<(DateTime<Utc>, IndexMap<String, i64>)> = kh[s..].to_vec();
            let now_k: IndexMap<String, i64> = cur.iter().map(|(k, c)| (k.clone(), c.totals.kills)).collect();
            if u > points.last().unwrap().0 {
                points.push((u, now_k));
            }
            for (k, v) in &points[0].1 {
                acc.insert(k.clone(), *v);
            }
            for i in 1..points.len() {
                let (from, to) = (points[i - 1].0, points[i].0);
                let lv = live_in(&live, from, to);
                for (key, n) in &points[i].1 {
                    let a = acc.get(key).copied().unwrap_or(0);
                    if *n < a {
                        acc.insert(key.clone(), *n); // Loot Tracker reset
                        continue;
                    }
                    let lk = lv.get(key).map(|x| x.kills).unwrap_or(0);
                    let miss = n - a - lk;
                    if miss > 0 {
                        match cur.get(key) {
                            Some(c) => gap_line(&mut lines, &c.ty, &c.name, c.last, from, to, miss, Value::Null),
                            None => {
                                let (t, nm) = key.split_once('|').unwrap_or((key.as_str(), ""));
                                gap_line(&mut lines, t, nm, 0, from, to, miss, Value::Null)
                            }
                        }
                        acc.insert(key.clone(), *n);
                    } else {
                        acc.insert(key.clone(), (*n).max(a + lk)); // live line not in the totals yet: counted once
                    }
                }
            }
        }
        for (key, c) in &cur {
            let mut k = c.totals.kills;
            if let Some(a) = acc.get(key) {
                k = k.max(*a);
            }
            base.insert(key.clone(), Totals { kills: k, drops: c.totals.drops.clone() });
        }
    } else {
        let b: Value = serde_json::from_str(trim(&read_text(&base_file).unwrap_or_default())).err_text()?;
        let t_base = parse_time_or_err(&ps_string(prop(&b, "t")))?;
        if u <= t_base {
            return Ok("Drop log gaps: none (no new Loot Tracker totals)".into());
        }
        let mut old: IndexMap<String, Totals> = IndexMap::new();
        for (k, v) in props(prop(&b, "k")) {
            old.insert(k, Totals { kills: ps_long(prop(&v, "kills")), drops: drops_of(prop(&v, "drops")) });
        }
        let lv = live_in(&live, t_base, u);
        for (key, c) in &cur {
            let o = old.get(key).cloned().unwrap_or_default();
            let l = lv.get(key).cloned().unwrap_or_default();
            let ct = &c.totals;
            if ct.kills < o.kills {
                base.insert(key.clone(), ct.clone()); // Loot Tracker reset
                continue;
            }
            let miss = ct.kills - o.kills - l.kills;
            let mut ids: IndexSet<String> = ct.drops.keys().cloned().collect();
            ids.extend(o.drops.keys().cloned());
            ids.extend(l.drops.keys().cloned());
            let g = |m: &IndexMap<String, i64>, id: &str| m.get(id).copied().unwrap_or(0);
            if miss > 0 {
                let items: Vec<Value> = ids
                    .iter()
                    .filter_map(|id| {
                        let q = g(&ct.drops, id) - g(&o.drops, id) - g(&l.drops, id);
                        (q > 0).then(|| json!([id.parse::<i64>().unwrap_or(0), q]))
                    })
                    .collect();
                gap_line(&mut lines, &c.ty, &c.name, c.last, t_base, u, miss, Value::Array(items));
                base.insert(key.clone(), ct.clone());
            } else {
                // Nothing missing. A live line the totals don't have yet is counted once only.
                let drops = ids.iter().map(|id| (id.clone(), g(&ct.drops, id).max(g(&o.drops, id) + g(&l.drops, id)))).collect();
                base.insert(key.clone(), Totals { kills: ct.kills.max(o.kills + l.kills), drops });
            }
        }
    }
    ensure_dir(&ctx.plugin_data());
    if !lines.is_empty() {
        let text: Vec<&str> = lines.iter().map(|l| l.0.as_str()).collect();
        append_text(&ctx.loot_gap_file(), &format!("{}\n", text.join("\n"))).err_text()?;
    }
    let k: Map<String, Value> = base.iter().map(|(k, t)| (k.clone(), base_json(t))).collect();
    let tmp = base_file.with_extension("json.tmp");
    write_text(&tmp, &ps_json(&json!({"t": prop(&kc, "updated").cloned().unwrap_or(Value::Null), "k": Value::Object(k)})))
        .err_text()?;
    std::fs::rename(&tmp, &base_file).err_text()?;
    let kills: i64 = lines.iter().map(|l| l.1).sum();
    Ok(if lines.is_empty() {
        "Drop log gaps: none".into()
    } else {
        format!("Drop log gaps: {kills} kills from {} entries added (played without the plugin)", lines.len())
    })
}
