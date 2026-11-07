// Bank contents, names, smart values and GE prices (bank.ps1). The contents come only from the OSRS Data Sync
// plugin's containers.json (plugin.rs containers). File formats: see the top of bank.ps1; every price file holds only
// YOUR items (price_ids).

use crate::clog::{bucket_url, ge_price, strip_file, PRICES_URL};
use crate::refresh::Ctx;
use crate::util::*;
use chrono::{Datelike, Local, Months, NaiveDate, TimeZone};
use indexmap::{IndexMap, IndexSet};
use regex::Regex;
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

const PRICES_HOUR_URL: &str = "https://prices.runescape.wiki/api/v1/osrs/1h?timestamp=";
const PRICES_DAY_URL: &str = "https://prices.runescape.wiki/api/v1/osrs/24h?timestamp=";
const GE_ITEMS_URL: &str = "https://prices.runescape.wiki/api/v1/osrs/mapping";
// Coins and platinum tokens have no GE price
const FIXED_PRICES: [(&str, i64); 2] = [("995", 1), ("13204", 1000)];
const BANK_FILLER: i64 = 20594;

pub type PriceMap = IndexMap<String, i64>;
type Pairs = Vec<(i64, i64)>;

fn dir(ctx: &Ctx) -> PathBuf {
    ctx.data.join("bank")
}
fn read_file(ctx: &Ctx, name: &str) -> Option<String> {
    non_empty(read_text(&dir(ctx).join(name)))
}
fn save(ctx: &Ctx, name: &str, text: &str) -> Res<()> {
    write_text(&dir(ctx).join(name), text).err_text()
}
fn parse(text: &str) -> Res<Value> {
    serde_json::from_str(trim(text)).err_text()
}
// Read-BankHash: a bank JSON file (or one property of it) as id -> value; empty when missing
fn read_hash(ctx: &Ctx, name: &str, field: Option<&str>) -> Res<Map<String, Value>> {
    let Some(text) = read_file(ctx, name) else { return Ok(Map::new()) };
    let mut v = parse(&text)?;
    if let Some(f) = field {
        v = prop(&v, f).cloned().unwrap_or(Value::Null);
    }
    Ok(match v {
        Value::Object(o) => o,
        _ => Map::new(),
    })
}
fn to_price_map(v: Option<&Value>) -> PriceMap {
    props(v).into_iter().map(|(k, x)| (k, ps_long(Some(&x)))).collect()
}
fn owned(prices: &PriceMap, ids: &IndexSet<String>) -> Value {
    let mut out = Map::new();
    for id in ids {
        if let Some(p) = prices.get(id) {
            out.insert(id.clone(), json!(p));
        }
    }
    Value::Object(out)
}

// Wiki image file for an item icon, for items that aren't in the collection log
pub fn bank_image(data_dir: &Path, id: &str) -> Option<String> {
    let items = read_json(&data_dir.join("bank").join("items.json"))?;
    let it = items.get(id)?;
    let file = it.get(1)?;
    truthy(file).then(|| ps_string(Some(file)))
}

// The plugin's list -> [(id, qty)], same ids added up, bank fillers dropped
fn from_item_list(list: &Pairs) -> Pairs {
    let mut out: IndexMap<i64, i64> = IndexMap::new();
    for (id, qty) in list {
        if *id == BANK_FILLER {
            continue;
        }
        *out.entry(*id).or_insert(0) += qty;
    }
    out.into_iter().filter(|(_, q)| *q > 0).collect()
}
fn pairs_json(list: &Pairs) -> String {
    format!("[{}]", list.iter().map(|(a, b)| format!("[{a},{b}]")).collect::<Vec<_>>().join(","))
}
// The same for a list read back from history.jsonl
fn value_pairs_json(v: Option<&Value>) -> String {
    let parts: Vec<String> = ps_array(v)
        .iter()
        .filter(|p| truthy(p))
        .map(|p| format!("[{},{}]", ps_long(p.get(0)), ps_long(p.get(1))))
        .collect();
    format!("[{}]", parts.join(","))
}
fn value_ids(v: Option<&Value>) -> Vec<String> {
    ps_array(v).iter().filter(|p| truthy(p)).map(|p| ps_string(p.get(0))).collect()
}

fn local_stamp(t: chrono::DateTime<chrono::Utc>) -> String {
    t.with_timezone(&Local).format("%H:%M:%S, %-d %b %Y").to_string()
}

// Called on Refresh; returns a short status message
pub fn update(ctx: &Ctx) -> Res<String> {
    ensure_dir(&dir(ctx));
    let hist = dir(ctx).join("history.jsonl");
    let last = last_line(&hist);
    let prev: Option<Value> = match &last {
        Some(l) => Some(parse(l)?),
        None => None,
    };
    let Some(plug) = crate::plugin::containers(ctx)? else {
        return Ok("Bank: nothing from OSRS Data Sync yet (log in with the plugin on and open your bank once)".into());
    };
    let items = from_item_list(&plug.bank);
    let saved = if plug.bank_at != 0 {
        Local.timestamp_millis_opt(plug.bank_at).single().map(|t| t.format("%H:%M:%S, %-d %b %Y").to_string()).unwrap_or_default()
    } else {
        format!("before {}", local_stamp(plug.updated))
    };
    let worn = from_item_list(&plug.equipment);
    let carried = from_item_list(&plug.inventory);
    let pouch = plug.rune_pouch.as_ref().map(from_item_list);

    // Offers are part of what's owned (the page counts them), so a change is a new line. No offers = same as a line without "ge"
    let no_empty = |s: &str| if s == "[]" { String::new() } else { s.to_string() };
    let ge_text = plug.ge.as_deref().map(no_empty).unwrap_or_default();
    let prev_ge = last.as_deref().and_then(|l| LINE_GE.captures(l)).map(|c| no_empty(&c[1])).unwrap_or_default();
    let now_sig = format!(
        "{}|{}|{}|True|{}|{ge_text}",
        pairs_json(&items),
        pairs_json(&worn),
        pairs_json(&carried),
        pouch.as_ref().map(pairs_json).unwrap_or_default()
    );
    let before = prev.as_ref().map(|p| {
        format!(
            "{}|{}|{}|{}|{}|{prev_ge}",
            value_pairs_json(prop(p, "items")),
            value_pairs_json(prop(p, "worn")),
            value_pairs_json(prop(p, "carried")),
            if prop(p, "worn").is_some() { "True" } else { "False" },
            if prop(p, "pouch").is_some() { value_pairs_json(prop(p, "pouch")) } else { String::new() }
        )
    });
    let mut status = "no change".to_string();
    let mut line_t: Option<String> = None;
    if before.as_deref() != Some(now_sig.as_str()) {
        let t = iso(now());
        let pouch_json = pouch.as_ref().map(|p| format!(",\"pouch\":{}", pairs_json(p))).unwrap_or_default();
        let ge_json = plug.ge.as_ref().map(|g| format!(",\"ge\":{g}")).unwrap_or_default();
        let line = format!(
            "{{\"t\":\"{t}\",\"saved\":{},\"src\":\"plugin\",\"items\":{},\"worn\":{},\"carried\":{}{pouch_json}{ge_json}}}",
            ps_str(&saved),
            pairs_json(&items),
            pairs_json(&worn),
            pairs_json(&carried)
        );
        append_text(&hist, &format!("{line}\n")).err_text()?;
        status = format!("saved ({} items, {} worn, {} carried)", items.len(), worn.len(), carried.len());
        line_t = Some(t);
    }
    // When the gear was last known ("seen" = when the plugin last wrote its file)
    let inv = plug.inv_layout.iter().map(|(a, b, c)| format!("[{a},{b},{c}]")).collect::<Vec<_>>().join(",");
    save(
        ctx,
        "gear.json",
        &format!("{{\"t\":\"{}\",\"src\":\"plugin\",\"seen\":\"{}\",\"inv\":[{inv}]}}", iso(now()), iso(plug.updated)),
    )?;

    // Items that just left the bank keep a price too
    let mut set: IndexSet<String> = IndexSet::new();
    for list in [&items, &worn, &carried] {
        for (id, _) in list {
            set.insert(id.to_string());
        }
    }
    if let Some(p) = &prev {
        for f in ["items", "worn", "carried"] {
            for id in value_ids(prop(p, f)) {
                set.insert(id);
            }
        }
    }
    let ids: Vec<String> = set.iter().cloned().collect();
    let names = update_items(ctx, &ids).unwrap_or_else(|e| format!("names unavailable: {e}"));
    let values = update_derived(ctx, &ids).unwrap_or_else(|e| format!("smart values unavailable: {e}"));
    let parts: Vec<String> = bank_parts(ctx, &ids)?.into_iter().filter(|p| !set.contains(p)).collect();
    if !parts.is_empty() {
        let _ = update_items(ctx, &parts);
    }
    // Items in Grand Exchange offers may never have been owned: the page needs their name too
    let ge: Vec<String> = ge_ids(ctx).into_iter().filter(|id| !set.contains(id)).collect();
    if !ge.is_empty() {
        let _ = update_items(ctx, &ge);
    }
    let live = match update_live_prices(ctx) {
        Ok(l) => Some(l),
        Err(e) => {
            eprintln!("Live prices unavailable: {e}");
            None
        }
    };
    let prices = update_prices(ctx, live.as_ref()).unwrap_or_else(|e| format!("prices unavailable: {e}"));
    let past = update_past_prices(ctx).unwrap_or_else(|e| format!("past prices unavailable: {e}"));
    let days = update_day_prices(ctx).unwrap_or_else(|e| format!("day prices unavailable: {e}"));
    let saves =
        update_save_prices(ctx, line_t.as_deref(), live.as_ref()).unwrap_or_else(|e| format!("save prices unavailable: {e}"));
    let mut worn_ids: Vec<String> = worn.iter().map(|(id, _)| id.to_string()).collect();
    if let Some(p) = &prev {
        worn_ids.extend(value_ids(prop(p, "worn")));
    }
    let _ = update_slots(ctx, &worn_ids);
    Ok(format!("Bank (OSRS Data Sync): {status} - {names} - {values} - {prices} - {past} - {days} - {saves}"))
}

// Equipment slot of worn items (wiki infobox_item: id -> page, then infobox_bonuses: page -> slot). "" = not found.
fn update_slots(ctx: &Ctx, ids: &[String]) -> Res<()> {
    let mut map = read_hash(ctx, "slots.json", None)?;
    let todo = sort_unique(ids.iter().filter(|id| !id.is_empty() && !map.contains_key(*id)).cloned().collect());
    if todo.is_empty() {
        return Ok(());
    }
    let or = todo.iter().map(|id| format!("{{'item_id','{id}'}}")).collect::<Vec<_>>().join(",");
    let q = format!("bucket('infobox_item').select('item_id','page_name').where(bucket.Or({or})).limit(500).run()");
    let mut pages: IndexMap<String, String> = IndexMap::new();
    for row in ps_each(prop(&ctx.web.get_json(&bucket_url(&q))?, "bucket")) {
        for id in ps_array(prop(&row, "item_id")) {
            let id = ps_string(Some(&id));
            if todo.contains(&id) {
                pages.insert(id, ps_string(prop(&row, "page_name")));
            }
        }
    }
    let mut slot_of: IndexMap<String, String> = IndexMap::new();
    let names = sort_unique(pages.values().cloned().collect());
    if !names.is_empty() {
        let or = names.iter().map(|n| format!("{{'page_name','{}'}}", n.replace('\'', "\\'"))).collect::<Vec<_>>().join(",");
        let q = format!("bucket('infobox_bonuses').select('page_name','equipment_slot').where(bucket.Or({or})).limit(500).run()");
        for row in ps_each(prop(&ctx.web.get_json(&bucket_url(&q))?, "bucket")) {
            let page = ps_string(prop(&row, "page_name"));
            if opt_truthy(prop(&row, "equipment_slot")) && !slot_of.contains_key(&page) {
                slot_of.insert(page, ps_string(prop(&row, "equipment_slot")));
            }
        }
    }
    for id in &todo {
        let slot = pages.get(id).filter(|p| !p.is_empty()).and_then(|p| slot_of.get(p)).cloned().unwrap_or_default();
        map.insert(id.clone(), Value::String(slot));
    }
    save(ctx, "slots.json", &ps_json(&Value::Object(map)))
}

// Every tradeable part id that the bank's untradeables are valued by (RuneLite list + derived.json)
pub fn bank_parts(ctx: &Ctx, ids: &[String]) -> Res<Vec<String>> {
    let rl = read_hash(ctx, "mapping.json", Some("map"))?;
    let derived = read_hash(ctx, "derived.json", None)?;
    let mut out: IndexSet<String> = IndexSet::new();
    for id in ids {
        for m in ps_array(rl.get(id)) {
            if truthy(&m) {
                out.insert(ps_string(m.get(0)));
            }
        }
        if let Some(d) = derived.get(id).filter(|d| truthy(d)) {
            for opt in ps_array(prop(d, "options")) {
                for p in ps_array(Some(&opt)) {
                    out.insert(ps_string(p.get(0)));
                }
            }
        }
    }
    Ok(out.into_iter().collect())
}

static DOSES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^(.*?)\s?\((\d+)\)$").unwrap());

// Smart values for ids not looked at before (see bank.ps1 Update-BankDerived)
fn update_derived(ctx: &Ctx, ids: &[String]) -> Res<String> {
    let mut derived = read_hash(ctx, "derived.json", None)?;
    let rl = read_hash(ctx, "mapping.json", Some("map"))?;
    let names = read_hash(ctx, "items.json", None)?;
    let todo: Vec<String> =
        ids.iter().filter(|id| !derived.contains_key(*id) && !rl.contains_key(*id) && opt_truthy(names.get(*id))).cloned().collect();
    if todo.is_empty() {
        return Ok("smart values stored".into());
    }
    // Every tradeable item (the GE's item list): ids, and lower-case name -> id
    let mut tradeable: IndexSet<String> = IndexSet::new();
    let mut by_name: IndexMap<String, String> = IndexMap::new();
    for it in ps_each(Some(&ctx.web.get_json(GE_ITEMS_URL)?)) {
        let id = ps_string(prop(&it, "id"));
        tradeable.insert(id.clone());
        by_name.entry(ps_string(prop(&it, "name")).to_lowercase()).or_insert(id);
    }

    let mut recipe_for: IndexMap<String, String> = IndexMap::new();
    let mut found = 0;
    for id in &todo {
        let name = ps_string(names.get(id).and_then(|n| n.get(0)));
        derived.insert(id.clone(), Value::Null);
        // Doses / charges: "Super restore(2)", "Slayer ring (5)" -> the same item with a GE price
        if let Some(c) = DOSES.captures(&name) {
            let base = c[1].to_string();
            let n: i64 = c[2].parse().unwrap_or(0);
            let mut sib: Vec<(i64, String)> = Vec::new();
            for k in 1..=10 {
                if k == n {
                    continue;
                }
                for cand in [format!("{base}({k})"), format!("{base} ({k})")] {
                    if let Some(sid) = by_name.get(&cand.to_lowercase()) {
                        sib.push((k, sid.clone()));
                        break;
                    }
                }
            }
            if !sib.is_empty() {
                let max = sib.iter().map(|s| s.0).max().unwrap();
                if max <= 4 && n < max {
                    let best = sib.iter().find(|s| s.0 == max).unwrap();
                    let share = ((n as f64 / best.0 as f64) * 10000.0).round_ties_even() / 10000.0;
                    derived.insert(id.clone(), json!({"via": "doses", "options": [[[best.1.parse::<i64>().unwrap_or(0), num(share)]]]}));
                } else {
                    let best = sib.iter().min_by_key(|s| (s.0 - n).abs()).unwrap();
                    derived.insert(id.clone(), json!({"via": "charges", "options": [[[best.1.parse::<i64>().unwrap_or(0), 1]]]}));
                }
                found += 1;
                continue;
            }
        }
        if tradeable.contains(id) {
            continue; // has (or had) its own GE price
        }
        recipe_for.insert(name, id.clone());
    }

    if !recipe_for.is_empty() {
        let keys: Vec<String> = recipe_for.keys().cloned().collect();
        let recipes = get_recipes(ctx, &keys)?;
        // Untradeable materials: one level deeper (e.g. a hilt that is itself made from tradeables)
        let deeper = sort_unique(
            recipes
                .values()
                .flatten()
                .flatten()
                .map(|m| m.0.clone())
                .filter(|m| !by_name.contains_key(&m.to_lowercase()))
                .collect(),
        );
        let sub = if deeper.is_empty() { IndexMap::new() } else { get_recipes(ctx, &deeper)? };
        for (name, id) in &recipe_for {
            let Some(opts) = recipes.get(&name.to_lowercase()) else { continue };
            let mut options: Vec<Value> = Vec::new();
            for mats in opts {
                let mut parts: Vec<Value> = Vec::new();
                for (mname, mq) in mats {
                    if let Some(mid) = by_name.get(&mname.to_lowercase()) {
                        parts.push(json!([mid.parse::<i64>().unwrap_or(0), num(*mq)]));
                        continue;
                    }
                    // Untradeable material: its own recipe's tradeable materials (first recipe that has some)
                    let Some(subs) = sub.get(&mname.to_lowercase()) else { continue };
                    for smats in subs {
                        let sp: Vec<Value> = smats
                            .iter()
                            .filter_map(|(sn, sq)| {
                                by_name.get(&sn.to_lowercase()).map(|sid| json!([sid.parse::<i64>().unwrap_or(0), num(sq * mq)]))
                            })
                            .collect();
                        if !sp.is_empty() {
                            parts.extend(sp);
                            break;
                        }
                    }
                }
                if !parts.is_empty() {
                    options.push(Value::Array(parts));
                }
            }
            if !options.is_empty() {
                derived.insert(id.clone(), json!({"via": "recipe", "options": options}));
                found += 1;
            }
        }
    }
    save(ctx, "derived.json", &ps_json(&Value::Object(derived)))?;
    Ok(format!("smart values: {found} of {} new items valued by their parts", todo.len()))
}

// Wiki recipes: output name (lower case) -> options, each a list of (material name, qty per item)
fn get_recipes(ctx: &Ctx, page_names: &[String]) -> Res<IndexMap<String, Vec<Vec<(String, f64)>>>> {
    let mut out: IndexMap<String, Vec<Vec<(String, f64)>>> = IndexMap::new();
    // [double]("0" + $x): "0" + the value as text, then a number
    let qty = |v: Option<&Value>| -> Res<f64> {
        let s = format!("0{}", ps_string(v));
        trim(&s).parse::<f64>().map_err(|_| format!("Cannot convert value \"{s}\" to type \"System.Double\"."))
    };
    for batch in page_names.chunks(25) {
        let or = batch
            .iter()
            .map(|n| format!("{{'page_name','{}'}}", n.replace('\\', "\\\\").replace('\'', "\\'")))
            .collect::<Vec<_>>()
            .join(",");
        let q = format!("bucket('recipe').select('page_name','production_json').where(bucket.Or({or})).limit(500).run()");
        let res = ctx.web.get_json(&bucket_url(&q))?;
        for row in ps_each(prop(&res, "bucket")) {
            let p: Option<Value> = match prop(&row, "production_json") {
                Some(Value::String(s)) => serde_json::from_str(s).ok(),
                _ => None,
            };
            let Some(p) = p else { continue };
            let output = prop(&p, "output").cloned().unwrap_or(Value::Null);
            if !opt_truthy(prop(&output, "name")) || ps_array(prop(&p, "materials")).is_empty() {
                continue;
            }
            let out_qty = qty(prop(&output, "quantity"))?.max(1.0);
            let mut mats = Vec::new();
            for m in ps_array(prop(&p, "materials")) {
                mats.push((ps_string(prop(&m, "name")), qty(prop(&m, "quantity"))? / out_qty));
            }
            out.entry(ps_string(prop(&output, "name")).to_lowercase()).or_default().push(mats);
        }
        pause(400);
    }
    Ok(out)
}

// Item names + wiki image files, only for ids not looked up before. Tradeables from the price API's item list,
// the rest from the wiki's item infobox data. data\bank\items.json: id -> [name, image file]
pub fn update_items(ctx: &Ctx, ids: &[String]) -> Res<String> {
    let mut map = read_hash(ctx, "items.json", None)?;
    let todo = sort_unique(ids.iter().filter(|id| !map.contains_key(*id)).cloned().collect());
    if todo.is_empty() {
        return Ok("names stored".into());
    }
    let mut wanted: IndexSet<String> = todo.iter().cloned().collect();
    for it in ps_each(Some(&ctx.web.get_json(GE_ITEMS_URL)?)) {
        let id = ps_string(prop(&it, "id"));
        if wanted.shift_remove(&id) {
            map.insert(id, json!([prop(&it, "name").cloned().unwrap_or(Value::Null), prop(&it, "icon").cloned().unwrap_or(Value::Null)]));
        }
    }
    let rest: Vec<String> = wanted.into_iter().collect();
    for batch in rest.chunks(40) {
        let or = batch.iter().map(|id| format!("{{'item_id','{id}'}}")).collect::<Vec<_>>().join(",");
        let q = format!("bucket('infobox_item').select('item_id','item_name','image').where(bucket.Or({or})).limit(500).run()");
        let res = ctx.web.get_json(&bucket_url(&q))?;
        for row in ps_each(prop(&res, "bucket")) {
            // Stackables list one picture per stack size; the last is the biggest pile (coins, runes...)
            let last = ps_array(prop(&row, "image")).pop().unwrap_or(Value::Null);
            let file = strip_file(&ps_string(Some(&last)));
            for id in ps_array(prop(&row, "item_id")) {
                let id = ps_string(Some(&id));
                if batch.contains(&id) && !map.contains_key(&id) {
                    map.insert(id, json!([ps_string(prop(&row, "item_name")), file]));
                }
            }
        }
        pause(400);
    }
    // Not on the wiki under that id: remembered so it isn't looked up again every Refresh
    for id in &todo {
        if !map.contains_key(id) {
            map.insert(id.clone(), json!([format!("Item {id}"), ""]));
        }
    }
    save(ctx, "items.json", &ps_json(&Value::Object(map)))?;
    Ok(format!("names updated ({} new)", todo.len()))
}

static HIST_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[(\d+),-?\d+\]").unwrap());
static KC_DROPS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""drops":\{([^}]*)\}"#).unwrap());
static KC_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""(\d+)":"#).unwrap());
static GE_LIST: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""ge"\s*:\s*\[([^\]]*)\]"#).unwrap());
static GE_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""id"\s*:\s*(\d+)"#).unwrap());
static LINE_GE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#","ge":(\[.*\])\}$"#).unwrap());

// Item ids in the plugin's current Grand Exchange offers (containers.json "ge")
fn ge_ids(ctx: &Ctx) -> Vec<String> {
    let text = read_text(&ctx.plugin_dir.join("containers.json")).unwrap_or_default();
    match GE_LIST.captures(&text) {
        Some(ge) => GE_ID.captures_iter(&ge[1]).map(|m| m[1].to_string()).collect(),
        None => Vec::new(),
    }
}

// The only items whose prices are kept: every id in any saved bank / gear list, every collection log item
// obtained, every item had as loot, plus the parts untradeables are valued by
pub fn price_ids(ctx: &Ctx) -> Res<IndexSet<String>> {
    let mut ids: IndexSet<String> = IndexSet::new();
    if let Some(h) = read_file(ctx, "history.jsonl") {
        for c in HIST_ID.captures_iter(&h) {
            ids.insert(c[1].to_string());
        }
    }
    for id in crate::clog::logged_ids(ctx) {
        ids.insert(id);
    }
    if let Some(kc) = read_text(&ctx.plugin_dir.join("killcounts.json")) {
        for d in KC_DROPS.captures_iter(&kc) {
            for m in KC_ID.captures_iter(&d[1]) {
                ids.insert(m[1].to_string());
            }
        }
    }
    for id in ge_ids(ctx) {
        ids.insert(id); // offers: the page compares them with the live price
    }
    let mapping = read_hash(ctx, "mapping.json", Some("map"))?;
    let derived = read_hash(ctx, "derived.json", None)?;
    for id in ids.clone() {
        for p in ps_array(mapping.get(&id)) {
            if truthy(&p) {
                ids.insert(ps_string(p.get(0)));
            }
        }
        if let Some(d) = derived.get(&id).filter(|d| truthy(d)) {
            for o in ps_array(prop(d, "options")) {
                for p in ps_array(Some(&o)) {
                    ids.insert(ps_string(p.get(0)));
                }
            }
        }
    }
    Ok(ids)
}

// Wiki price API data -> id -> gp (the buy/sell rule of ge_price, `refs` picks a side when they disagree)
fn price_map(data: Option<&Value>, hi: &str, lo: &str, hiw: &str, low: &str, refs: Option<&PriceMap>) -> PriceMap {
    let mut out = PriceMap::new();
    for (id, v) in props(data) {
        let r = refs.and_then(|m| m.get(&id)).map(|x| *x as f64);
        let g = ge_price(ps_f64(prop(&v, hi)), ps_f64(prop(&v, lo)), ps_f64(prop(&v, hiw)), ps_f64(prop(&v, low)), r);
        if let Some(g) = g.filter(|g| *g != 0.0) {
            out.insert(id, g.round_ties_even() as i64);
        }
    }
    for (id, p) in FIXED_PRICES {
        out.insert(id.to_string(), p);
    }
    out
}
fn download_prices(ctx: &Ctx, url: &str, hourly: bool, refs: Option<&PriceMap>) -> Res<PriceMap> {
    let v = ctx.web.get_json(url)?;
    Ok(if hourly {
        price_map(prop(&v, "data"), "avgHighPrice", "avgLowPrice", "highPriceVolume", "lowPriceVolume", refs)
    } else {
        price_map(prop(&v, "data"), "high", "low", "highTime", "lowTime", refs)
    })
}

// GE prices of your items, set once a day (the first Refresh after the 00:00 UTC reset); items new to the bank
// later that day get theirs from the same Refresh's live download
fn update_prices(ctx: &Ctx, live: Option<&PriceMap>) -> Res<String> {
    let ids = price_ids(ctx)?;
    if let Some(old) = read_file(ctx, "prices.json") {
        let o = parse(&old)?;
        let ot = parse_time_or_err(&ps_string(prop(&o, "t")))?;
        let is_today = ot >= utc_midnight(today_utc());
        if opt_truthy(prop(&o, "owned")) && is_today {
            let mut have = props(prop(&o, "prices")).into_iter().collect::<Map<String, Value>>();
            let mut added = 0;
            if let Some(live) = live {
                for id in &ids {
                    if !have.contains_key(id) {
                        if let Some(p) = live.get(id) {
                            have.insert(id.clone(), json!(p));
                            added += 1;
                        }
                    }
                }
            }
            if added == 0 {
                return Ok("prices stored (today's)".into());
            }
            let t = prop(&o, "t").cloned().unwrap_or(Value::Null);
            save(ctx, "prices.json", &ps_json(&json!({"t": t, "owned": true, "prices": Value::Object(have)})))?;
            return Ok(format!("prices stored (today's, {added} new items added)"));
        }
        // The last Refresh day's prices are kept for the value graph before they're replaced
        if (opt_truthy(prop(&o, "all")) || opt_truthy(prop(&o, "owned"))) && !is_today {
            save_day_prices(ctx, &ot.format("%Y-%m-%d").to_string(), &to_price_map(prop(&o, "prices")))?;
        }
    }
    let all = match live {
        Some(l) => l.clone(),
        None => download_prices(ctx, PRICES_URL, false, None)?,
    };
    let prices = owned(&all, &ids);
    let n = prices.as_object().map(|o| o.len()).unwrap_or(0);
    save(ctx, "prices.json", &ps_json(&json!({"t": iso(now()), "owned": true, "prices": prices})))?;
    Ok(format!("prices updated ({n} items)"))
}

// GE prices right now (prices-live.json, every Refresh) and the hour before today's reset (prices-reset.json,
// once a day; the reference that picks a side when a live buy/sell pair disagrees). Returns the live map.
fn update_live_prices(ctx: &Ctx) -> Res<PriceMap> {
    let t = iso(now());
    let reset = utc_midnight(today_utc()).timestamp();
    let ids = price_ids(ctx)?;
    let old = match read_file(ctx, "prices-reset.json") {
        Some(s) => Some(parse(&s)?),
        None => None,
    };
    let hour = match old.as_ref().filter(|o| ps_long(prop(o, "reset")) == reset) {
        Some(o) => to_price_map(prop(o, "prices")),
        None => {
            let hour = download_prices(ctx, &format!("{PRICES_HOUR_URL}{}", reset - 3600), true, None)?;
            save(ctx, "prices-reset.json", &ps_json(&json!({"t": t, "reset": reset, "prices": owned(&hour, &ids)})))?;
            hour
        }
    };
    let live = download_prices(ctx, PRICES_URL, false, Some(&hour))?;
    save(ctx, "prices-live.json", &ps_json(&json!({"t": t, "prices": owned(&live, &ids)})))?;
    Ok(live)
}

// Period key -> start date (UTC dates: days start at the game's daily reset); "all" = the first saved bank
fn period_dates(ctx: &Ctx) -> IndexMap<&'static str, String> {
    let today = today_utc();
    let months = |n: u32| today.checked_sub_months(Months::new(n)).unwrap_or(today);
    let mut d: IndexMap<&'static str, NaiveDate> = IndexMap::new();
    d.insert("2d", today - chrono::Days::new(1));
    d.insert("3d", today - chrono::Days::new(2));
    d.insert("1w", today - chrono::Days::new(7));
    d.insert("2w", today - chrono::Days::new(14));
    d.insert("month", today.with_day(1).unwrap());
    d.insert("1m", months(1));
    d.insert("2m", months(2));
    d.insert("3m", months(3));
    d.insert("6m", months(6));
    d.insert("year", today.with_ordinal(1).unwrap());
    d.insert("1y", months(12));
    d.insert("2y", months(24));
    d.insert("3y", months(36));
    d.insert("4y", months(48));
    d.insert("5y", months(60));
    let first = read_lines(&dir(ctx).join("history.jsonl")).into_iter().find(|l| !l.is_empty());
    if let Some(t) = first.as_deref().and_then(|l| T_FIELD.captures(l)).and_then(|c| parse_time(&c[1])) {
        d.insert("all", t.date_naive());
    }
    d.into_iter().map(|(k, v)| (k, v.format("%Y-%m-%d").to_string())).collect()
}
static T_FIELD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""t":"([^"]+)""#).unwrap());

fn date_secs(date: &str) -> i64 {
    NaiveDate::parse_from_str(date, "%Y-%m-%d").map(|d| utc_midnight(d).timestamp()).unwrap_or(0)
}
fn past_url(date: &str) -> String {
    format!("{PRICES_DAY_URL}{}", date_secs(date) - 86400)
}
fn past_dir(ctx: &Ctx) -> PathBuf {
    dir(ctx).join("prices-past")
}
fn needed_dates(ctx: &Ctx) -> Vec<String> {
    let mut v: Vec<String> = period_dates(ctx).values().cloned().collect();
    v.sort();
    v.dedup();
    v
}

// The downloads this Refresh needs (the Refresh starts them with the hiscores)
pub fn past_urls(ctx: &Ctx) -> Vec<String> {
    needed_dates(ctx).iter().filter(|d| !past_dir(ctx).join(format!("{d}.json")).exists()).map(|d| past_url(d)).collect()
}

// Price moves over the page's periods: each period's baseline = the wiki's 24h average of the day before it starts
fn update_past_prices(ctx: &Ctx) -> Res<String> {
    let pd = past_dir(ctx);
    ensure_dir(&pd);
    let dates = period_dates(ctx);
    let need = needed_dates(ctx);
    let mut got = 0;
    for date in &need {
        let f = pd.join(format!("{date}.json"));
        if f.exists() {
            continue;
        }
        let r = download_prices(ctx, &past_url(date), true, None)
            .and_then(|day| Ok(owned(&day, &price_ids(ctx)?)))
            .and_then(|p| write_text(&f, &ps_json(&p)).err_text());
        match r {
            Ok(()) => got += 1,
            Err(e) => eprintln!("Prices of {date} unavailable: {e}"),
        }
    }
    if let Ok(rd) = std::fs::read_dir(&pd) {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if let Some(base) = n.strip_suffix(".json") {
                if !need.iter().any(|d| d == base) {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
    }
    let ids = price_ids(ctx)?;
    let mut tables: IndexMap<String, Value> = IndexMap::new();
    let mut out = Map::new();
    for (k, date) in &dates {
        if !tables.contains_key(date) {
            let f = pd.join(format!("{date}.json"));
            let Some(text) = read_text(&f) else { continue };
            let all = to_price_map(Some(&parse(&text)?));
            tables.insert(date.clone(), owned(&all, &ids));
        }
        out.insert(k.to_string(), json!({"date": date, "prices": tables[date].clone()}));
    }
    let n = out.len();
    save(ctx, "prices-past.json", &ps_json(&Value::Object(out)))?;
    Ok(format!("past prices: {n} periods ({got} downloaded)"))
}

// prices-days.json: each past day's once-a-day prices, kept when the next day's replace them
fn save_day_prices(ctx: &Ctx, date: &str, prices: &PriceMap) -> Res<()> {
    let mut days = read_hash(ctx, "prices-days.json", None)?;
    if days.contains_key(date) {
        return Ok(());
    }
    days.insert(date.to_string(), owned(prices, &price_ids(ctx)?));
    let mut keys: Vec<String> = days.keys().cloned().collect();
    keys.sort();
    let mut out = Map::new();
    for k in keys {
        let v = days.get(&k).cloned().unwrap_or(Value::Null);
        out.insert(k, v);
    }
    save(ctx, "prices-days.json", &ps_json(&Value::Object(out)))
}

static T_DATE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""t":"(\d{4}-\d\d-\d\d)"#).unwrap());

// Days from before prices-days.json existed are filled once from the wiki (the hour before that day's reset)
fn update_day_prices(ctx: &Ctx) -> Res<String> {
    let Some(hist) = read_file(ctx, "history.jsonl") else { return Ok("day prices: none needed".into()) };
    let today = today_utc().format("%Y-%m-%d").to_string();
    let have: Vec<String> = read_hash(ctx, "prices-days.json", None)?.keys().cloned().collect();
    let mut need: Vec<String> = T_DATE.captures_iter(&hist).map(|c| c[1].to_string()).collect();
    need.sort();
    need.dedup();
    need.retain(|d| *d < today && !have.contains(d));
    for date in &need {
        let hour = download_prices(ctx, &format!("{PRICES_HOUR_URL}{}", date_secs(date) - 3600), true, None)?;
        save_day_prices(ctx, date, &hour)?;
    }
    Ok(format!("day prices: {} filled", need.len()))
}

static LINE_T: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"^\{"t":"([^"]+)""#).unwrap());
static SAVE_T: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(?m)^\{"t":"([^"]+)""#).unwrap());

// Value graph snapshots: one prices-saves.jsonl line per bank history line, with the GE prices of when it was made
fn update_save_prices(ctx: &Ctx, t: Option<&str>, live: Option<&PriceMap>) -> Res<String> {
    let hist = dir(ctx).join("history.jsonl");
    if !hist.exists() {
        return Ok("save prices: none needed".into());
    }
    let file = dir(ctx).join("prices-saves.jsonl");
    let have: IndexSet<String> =
        read_text(&file).map(|s| SAVE_T.captures_iter(&s).map(|c| c[1].to_string()).collect()).unwrap_or_default();
    let now_s = now().timestamp();
    let mut hours: IndexMap<i64, PriceMap> = IndexMap::new();
    let mut add = String::new();
    let mut prev_text = String::new();
    let mut n = 0;
    for text in read_lines(&hist) {
        if trim(&text).is_empty() {
            continue;
        }
        let lt = LINE_T.captures(&text).map(|c| c[1].to_string()).unwrap_or_default();
        if !lt.is_empty() && !have.contains(&lt) {
            let mut prices: Option<PriceMap> = None;
            if live.is_some() && Some(lt.as_str()) == t {
                prices = live.cloned();
            } else {
                let mut hour = parse_time_or_err(&lt)?.timestamp();
                hour -= hour.rem_euclid(3600);
                if hour + 3600 <= now_s {
                    if !hours.contains_key(&hour) {
                        let p = download_prices(ctx, &format!("{PRICES_HOUR_URL}{hour}"), true, None)?;
                        hours.insert(hour, p);
                    }
                    prices = hours.get(&hour).cloned();
                }
            }
            if let Some(prices) = prices {
                let both = format!("{text}{prev_text}");
                let want: IndexSet<String> = HIST_ID.captures_iter(&both).map(|c| c[1].to_string()).collect();
                let want: Vec<String> = want.into_iter().collect();
                let mut all = want.clone();
                all.extend(bank_parts(ctx, &want)?);
                let mut trim_map = Map::new();
                for id in all {
                    if let Some(p) = prices.get(&id) {
                        trim_map.insert(id, json!(p));
                    }
                }
                add.push_str(&ps_json(&json!({"t": lt, "prices": Value::Object(trim_map)})));
                add.push('\n');
                n += 1;
            }
        }
        prev_text = text;
    }
    if n > 0 {
        append_text(&file, &add).err_text()?;
    }
    Ok(format!("save prices: {n} stored ({} hours downloaded)", hours.len()))
}
