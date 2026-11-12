// Optional one-time import of older progress from Wise Old Man into data\history.jsonl. Only snapshots
// OLDER than the first local snapshot, converted to the official hiscores format and kept only when something
// changed. A backup of history.jsonl is written first. 50 snapshots per request, 3.5 s apart.
//
// Wise Old Man import (moved here from wom.ps1 when the PowerShell version was retired):
// Optional one-time import of older progress from Wise Old Man (wiseoldman.net) into data\history.jsonl.
// Used by the dashboard's "Import from Wise Old Man" banner (server.ps1 POST /api/wom) and by tools\import-wom.ps1.
// Only snapshots OLDER than the first local snapshot are imported, converted to the official hiscores format and
// de-duplicated (kept only when something changed). A backup of history.jsonl is written first.
// Wise Old Man is only contacted when the player chooses to import: 50 snapshots per request, 3.5 s apart.
// Dot-sourced; needs nothing else.

use crate::net::{Web, UA};
use crate::util::*;
use chrono::Local;
use indexmap::IndexMap;
use serde_json::{json, Value};
use std::path::Path;

pub struct Imported {
    pub kept: usize,
    pub from: String,
    pub to: String,
}

fn norm(s: &str) -> String {
    s.to_lowercase().chars().filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit()).collect()
}

pub fn import(web: &Web, player: &str, history: &Path) -> Res<Imported> {
    if player.is_empty() {
        return Err("No player name.".into());
    }
    let no_history = || "No history yet - press Update once first.".to_string();
    if !history.exists() {
        return Err(no_history());
    }
    let local: Vec<String> = read_lines(history).into_iter().filter(|l| !trim(l).is_empty()).collect();
    if local.is_empty() {
        return Err(no_history());
    }
    if local.iter().any(|l| l.contains(r#""src":"wom""#)) {
        return Err("Wise Old Man history was already imported.".into());
    }
    let mut template: Value = serde_json::from_str(trim(local.last().unwrap())).err_text()?;
    let mut first: Option<chrono::DateTime<chrono::Utc>> = None;
    for l in &local {
        let v: Value = serde_json::from_str(trim(l)).err_text()?;
        let t = parse_time_or_err(&ps_string(prop(&v, "t")))?;
        first = Some(first.map_or(t, |f| f.min(t)));
    }
    let end = iso_ms(first.unwrap() - chrono::Duration::seconds(1));

    // Every Wise Old Man snapshot before the first local one (50 per page, rate-limit friendly)
    let mut snaps: Vec<Value> = Vec::new();
    let mut offset = 0;
    loop {
        let url = format!(
            "https://api.wiseoldman.net/v2/players/{}/snapshots?startDate=2000-01-01T00:00:00.000Z&endDate={end}&limit=50&offset={offset}",
            escape_data(player)
        );
        let got = web.fetch(&url, UA);
        let page: Vec<Value> = match (got.status, got.text()) {
            (200..=299, Some(t)) => match serde_json::from_str::<Value>(trim(&t)) {
                Ok(v) => ps_each(Some(&v)),
                Err(_) => return Err("Could not reach Wise Old Man. Try again later.".into()),
            },
            (404, _) => return Err(format!("Wise Old Man doesn't track '{player}'. Nothing to import.")),
            (429, _) => return Err("Wise Old Man is busy (too many requests). Try again in a few minutes.".into()),
            _ => return Err("Could not reach Wise Old Man. Try again later.".into()),
        };
        let full = page.len() == 50;
        snaps.extend(page);
        offset += 50;
        eprintln!("Wise Old Man: fetched {} snapshots...", snaps.len());
        if !full {
            break;
        }
        pause(3500);
    }
    if snaps.is_empty() {
        return Err(format!(
            "Wise Old Man has no snapshots of '{player}' from before your first Update. Nothing to import."
        ));
    }
    let created = |s: &Value| parse_time(&ps_string(prop(s, "createdAt")));
    snaps.sort_by_key(|s| created(s));

    // Official names -> Wise Old Man keys
    let aliases: [(&str, &str); 2] = [("runecraft", "runecrafting"), ("tombsofamascutexpertmode", "tombsofamascutexpert")];
    let mut wom_keys: IndexMap<String, (String, String)> = IndexMap::new();
    let last_data = prop(snaps.last().unwrap(), "data").cloned().unwrap_or(Value::Null);
    for grp in ["skills", "bosses", "activities"] {
        for (name, _) in props(prop(&last_data, grp)) {
            wom_keys.insert(norm(&name), (grp.to_string(), name));
        }
    }
    let find_key = |name: &str| -> Option<(String, String)> {
        let mut k = norm(name);
        if let Some((_, to)) = aliases.iter().find(|(from, _)| *from == k) {
            k = to.to_string();
        }
        wom_keys.get(&k).cloned()
    };

    // Convert + de-duplicate (the template is the newest local snapshot; its values are replaced each time)
    let mut lines: Vec<String> = Vec::new();
    let mut last_sig: Option<String> = None;
    for w in &snaps {
        let data = prop(w, "data").cloned().unwrap_or(Value::Null);
        let lookup = |k: &Option<(String, String)>| -> Option<Value> {
            let (g, n) = k.as_ref()?;
            prop(&data, g).and_then(|x| prop(x, n)).filter(|v| truthy(v)).cloned()
        };
        let d = template.get_mut("d").ok_or("The newest snapshot has no hiscores data")?;
        if let Some(Value::Array(skills)) = d.get_mut("skills") {
            for s in skills.iter_mut() {
                let k = find_key(&ps_string(prop(s, "name")));
                let (xp, level, rank) = match lookup(&k) {
                    Some(v) => (ps_long(prop(&v, "experience")), ps_long(prop(&v, "level")), ps_long(prop(&v, "rank"))),
                    None => (-1, 1, -1),
                };
                if let Some(o) = s.as_object_mut() {
                    o.insert("xp".into(), json!(xp));
                    o.insert("level".into(), json!(level));
                    o.insert("rank".into(), json!(rank));
                }
            }
        }
        if let Some(Value::Array(acts)) = d.get_mut("activities") {
            for a in acts.iter_mut() {
                let k = find_key(&ps_string(prop(a, "name")));
                let (score, rank) = match lookup(&k) {
                    Some(v) => {
                        let field = if k.as_ref().map(|k| k.0 == "bosses").unwrap_or(false) { "kills" } else { "score" };
                        (ps_long(prop(&v, field)), ps_long(prop(&v, "rank")))
                    }
                    None => (-1, -1),
                };
                if let Some(o) = a.as_object_mut() {
                    o.insert("score".into(), json!(score));
                    o.insert("rank".into(), json!(rank));
                }
            }
        }
        let d = &template["d"];
        let mut sig: Vec<String> = ps_each(prop(d, "skills")).iter().map(|s| ps_string(prop(s, "xp"))).collect();
        sig.extend(ps_each(prop(d, "activities")).iter().map(|a| ps_string(prop(a, "score"))));
        let sig = sig.join(",");
        if last_sig.as_deref() == Some(sig.as_str()) {
            continue;
        }
        last_sig = Some(sig);
        let t = created(w).map(iso).unwrap_or_default();
        lines.push(format!("{{\"t\":\"{t}\",\"src\":\"wom\",\"d\":{}}}", ps_json(d)));
    }

    let dir = history.parent().unwrap_or(Path::new("."));
    let backup = dir.join(format!("history.backup-{}.jsonl", now().with_timezone(&Local).format("%Y%m%d-%H%M%S")));
    std::fs::copy(history, &backup).err_text()?;
    // [IO.File]::WriteAllLines: every line ends with the system's line break
    let nl = if cfg!(windows) { "\r\n" } else { "\n" };
    let mut out = String::new();
    for l in lines.iter().chain(local.iter()) {
        out.push_str(l);
        out.push_str(nl);
    }
    write_text(history, &out).err_text()?;
    Ok(Imported {
        kept: lines.len(),
        from: ps_string(prop(&snaps[0], "createdAt")),
        to: ps_string(prop(snaps.last().unwrap(), "createdAt")),
    })
}
