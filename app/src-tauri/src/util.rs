// Small helpers that make Rust behave like the PowerShell 5.1 scripts it replaces, so both write the same files:
// reading text like [IO.File]::ReadAllText / ReadAllLines, JSON written like ConvertTo-Json -Compress (same escapes:
// ' < > & become \u0027 \u003c \u003e \u0026), times like .NET's "o" format, and PowerShell's idea of "true"/"empty".

use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, TimeZone, Utc};
use serde_json::Value;
use std::fs;
use std::io::Write;
use std::path::Path;
use std::sync::LazyLock;

// ---- files ----

// The whole file as text (a UTF-8 BOM is dropped, like ReadAllText), or None when it doesn't exist
pub fn read_text(path: &Path) -> Option<String> {
    let bytes = fs::read(path).ok()?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    Some(match text.strip_prefix('\u{feff}') {
        Some(t) => t.to_string(),
        None => text,
    })
}

// Like ReadAllText(...).Split([char[]]"`r`n", RemoveEmptyEntries): every non-empty piece between \r / \n
pub fn split_lines(text: &str) -> Vec<&str> {
    text.split(['\r', '\n']).filter(|l| !l.is_empty()).collect()
}

// Like ReadAllLines: lines split at \r\n, \n or \r (a final line break doesn't add an empty line)
pub fn read_lines(path: &Path) -> Vec<String> {
    let Some(text) = read_text(path) else { return Vec::new() };
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                out.push(std::mem::take(&mut cur));
            }
            '\n' => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

// The last line that isn't blank (`Where-Object { $_.Trim() } | Select-Object -Last 1`)
pub fn last_line(path: &Path) -> Option<String> {
    read_lines(path).into_iter().rev().find(|l| !trim(l).is_empty())
}

// PowerShell's `if (-not $text)`: a missing OR empty file counts as missing
pub fn non_empty(text: Option<String>) -> Option<String> {
    text.filter(|t| !t.is_empty())
}

// .NET String.Trim(): Unicode white space at both ends
pub fn trim(s: &str) -> &str {
    s.trim_matches(char::is_whitespace)
}

// [IO.File]::WriteAllText(path, text, UTF-8 without BOM)
pub fn write_text(path: &Path, text: &str) -> std::io::Result<()> {
    fs::write(path, text.as_bytes())
}

// [IO.File]::AppendAllText
pub fn append_text(path: &Path, text: &str) -> std::io::Result<()> {
    let mut f = fs::OpenOptions::new().create(true).append(true).open(path)?;
    f.write_all(text.as_bytes())
}

pub fn ensure_dir(path: &Path) {
    let _ = fs::create_dir_all(path);
}

// A JSON file parsed (keys in file order), None when missing or not valid JSON
pub fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_str(&read_text(path)?).ok()
}

// ---- JSON like PowerShell 5.1's ConvertTo-Json -Compress ----

pub fn ps_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\'' | '<' | '>' | '&' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn ps_json(v: &Value) -> String {
    let mut out = String::new();
    write_json(v, &mut out);
    out
}

fn write_json(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            if n.is_i64() || n.is_u64() {
                out.push_str(&n.to_string())
            } else {
                out.push_str(&fmt_double(n.as_f64().unwrap_or(0.0)))
            }
        }
        Value::String(s) => out.push_str(&ps_str(s)),
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_json(x, out);
            }
            out.push(']');
        }
        Value::Object(o) => {
            out.push('{');
            for (i, (k, x)) in o.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&ps_str(k));
                out.push(':');
                write_json(x, out);
            }
            out.push('}');
        }
    }
}

// A double as .NET writes it: whole numbers without ".0"
pub fn fmt_double(f: f64) -> String {
    if f.fract() == 0.0 && f.abs() < 1e15 {
        format!("{}", f as i64)
    } else {
        format!("{f}")
    }
}

// A JSON number from a double (whole numbers stay integers, like PowerShell writes them)
pub fn num(f: f64) -> Value {
    if f.fract() == 0.0 && f.abs() < 1e15 {
        Value::from(f as i64)
    } else {
        serde_json::Number::from_f64(f).map(Value::Number).unwrap_or(Value::Null)
    }
}

// ---- PowerShell value rules ----

// `if ($x)`: $null, $false, 0, "" and an empty list are false; a one-item list is as true as its item
pub fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => match a.len() {
            0 => false,
            1 => truthy(&a[0]),
            _ => true,
        },
        Value::Object(_) => true,
    }
}

pub fn opt_truthy(v: Option<&Value>) -> bool {
    v.map(truthy).unwrap_or(false)
}

// `@($x)`: a list stays a list, $null becomes a one-item list holding $null, anything else a one-item list
pub fn ps_array(v: Option<&Value>) -> Vec<Value> {
    match v {
        Some(Value::Array(a)) => a.clone(),
        Some(x) => vec![x.clone()],
        None => vec![Value::Null],
    }
}

// `foreach ($x in $y)` (no @()): $null gives no items at all
pub fn ps_each(v: Option<&Value>) -> Vec<Value> {
    match v {
        Some(Value::Array(a)) => a.clone(),
        Some(Value::Null) | None => Vec::new(),
        Some(x) => vec![x.clone()],
    }
}

// `"$x"` / [string]$x
pub fn ps_string(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Bool(b)) => (if *b { "True" } else { "False" }).into(),
        Some(Value::Number(n)) => {
            if n.is_i64() || n.is_u64() {
                n.to_string()
            } else {
                fmt_double(n.as_f64().unwrap_or(0.0))
            }
        }
        Some(Value::Array(a)) => a.iter().map(|x| ps_string(Some(x))).collect::<Vec<_>>().join(" "),
        Some(Value::Object(_)) => String::new(),
    }
}

// [long]$x / [int]$x: numbers round half to even (like .NET), numeric text is parsed, $null is 0
pub fn ps_long(v: Option<&Value>) -> i64 {
    match v {
        Some(Value::Number(n)) => n.as_i64().unwrap_or_else(|| n.as_f64().unwrap_or(0.0).round_ties_even() as i64),
        Some(Value::String(s)) => trim(s).parse::<f64>().map(|f| f.round_ties_even() as i64).unwrap_or(0),
        Some(Value::Bool(b)) => *b as i64,
        _ => 0,
    }
}

pub fn ps_f64(v: Option<&Value>) -> Option<f64> {
    match v {
        Some(Value::Number(n)) => n.as_f64(),
        Some(Value::String(s)) => trim(s).parse::<f64>().ok(),
        _ => None,
    }
}

// Object property by name (None for non-objects), like $obj.name
pub fn prop<'a>(v: &'a Value, name: &str) -> Option<&'a Value> {
    v.as_object().and_then(|o| o.get(name))
}

// The properties of an object as (name, value), like $obj.PSObject.Properties ($null / non-objects: none)
pub fn props(v: Option<&Value>) -> Vec<(String, Value)> {
    match v {
        Some(Value::Object(o)) => o.iter().map(|(k, x)| (k.clone(), x.clone())).collect(),
        _ => Vec::new(),
    }
}

// [uri]::EscapeDataString: everything but A-Z a-z 0-9 - _ . ~ as %XX
pub fn escape_data(s: &str) -> String {
    const SET: &percent_encoding::AsciiSet =
        &percent_encoding::NON_ALPHANUMERIC.remove(b'-').remove(b'_').remove(b'.').remove(b'~');
    percent_encoding::utf8_percent_encode(s, SET).to_string()
}

// ---- time ----

// "Now". Tests can fix it (OSRS_DASH_NOW=<ISO time>) so two runs write the same times.
static FIXED_NOW: LazyLock<Option<DateTime<Utc>>> =
    LazyLock::new(|| std::env::var("OSRS_DASH_NOW").ok().and_then(|s| parse_time(&s)));

pub fn now() -> DateTime<Utc> {
    FIXED_NOW.unwrap_or_else(Utc::now)
}

// .NET's "o" format of a UTC time: 2026-11-02T10:00:00.1234567Z
pub fn iso(t: DateTime<Utc>) -> String {
    format!("{}.{:07}Z", t.format("%Y-%m-%dT%H:%M:%S"), t.timestamp_subsec_nanos() / 100)
}

// "yyyy-MM-ddTHH:mm:ss.fffZ"
pub fn iso_ms(t: DateTime<Utc>) -> String {
    format!("{}.{:03}Z", t.format("%Y-%m-%dT%H:%M:%S"), t.timestamp_subsec_millis())
}

// [datetime]::Parse of an ISO time (with Z / an offset, or without: then it is local time)
pub fn parse_time(s: &str) -> Option<DateTime<Utc>> {
    let s = trim(s);
    if let Ok(t) = DateTime::parse_from_rfc3339(s) {
        return Some(t.with_timezone(&Utc));
    }
    for f in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M"] {
        if let Ok(n) = NaiveDateTime::parse_from_str(s, f) {
            return Local.from_local_datetime(&n).earliest().map(|t| t.with_timezone(&Utc));
        }
    }
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .ok()
        .and_then(|d| Local.from_local_datetime(&d.and_hms_opt(0, 0, 0)?).earliest())
        .map(|t| t.with_timezone(&Utc))
}

pub fn parse_time_or_err(s: &str) -> Result<DateTime<Utc>, String> {
    parse_time(s).ok_or_else(|| format!("String was not recognized as a valid DateTime: {s}"))
}

// The UTC date at 00:00 (the game's daily reset)
pub fn utc_midnight(d: NaiveDate) -> DateTime<Utc> {
    Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap())
}

pub fn today_utc() -> NaiveDate {
    now().date_naive()
}

pub type Res<T> = Result<T, String>;

pub trait ErrText<T> {
    fn err_text(self) -> Res<T>;
}
impl<T, E: std::fmt::Display> ErrText<T> for Result<T, E> {
    fn err_text(self) -> Res<T> {
        self.map_err(|e| e.to_string())
    }
}

// Pauses between wiki requests (tests skip them: OSRS_DASH_NO_WAIT=1)
pub fn pause(ms: u64) {
    if std::env::var_os("OSRS_DASH_NO_WAIT").is_none() {
        std::thread::sleep(std::time::Duration::from_millis(ms));
    }
}

// PowerShell's culture-aware string sort (Sort-Object), close enough for names: case-insensitive first,
// punctuation such as "-" weighs less than letters
pub fn culture_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let key = |s: &str| -> String { s.chars().filter(|c| c.is_alphanumeric() || *c == ' ').collect::<String>().to_lowercase() };
    key(a).cmp(&key(b)).then_with(|| a.len().cmp(&b.len())).then_with(|| b.cmp(a))
}

// Sort-Object -Unique
pub fn sort_unique(mut v: Vec<String>) -> Vec<String> {
    v.sort_by(|a, b| culture_cmp(a, b));
    v.dedup_by(|a, b| a.to_lowercase() == b.to_lowercase());
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn json_like_powershell() {
        let v: Value = serde_json::from_str(r#"{"a":"x<>&'\"\\é\t","b":1.0,"c":0.6667,"e":[],"f":null}"#).unwrap();
        assert_eq!(ps_json(&v), r#"{"a":"x\u003c\u003e\u0026\u0027\"\\é\t","b":1,"c":0.6667,"e":[],"f":null}"#);
    }
    #[test]
    fn sort_like_powershell() {
        let v: Vec<String> = ["b-c", "bc", "B", "a", "Ab", "a b"].iter().map(|s| s.to_string()).collect();
        let mut s = v.clone();
        s.sort_by(|a, b| culture_cmp(a, b));
        assert_eq!(s.join("|"), "a|a b|Ab|B|bc|b-c");
    }
    #[test]
    fn iso_format() {
        let t = parse_time("2026-11-03T00:09:38.3726975Z").unwrap();
        assert_eq!(iso(t), "2026-11-03T00:09:38.3726975Z");
    }
}
