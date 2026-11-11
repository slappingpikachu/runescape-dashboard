// Google Drive sync without the Google Drive app: the dashboard itself keeps each device's sync file (sync.rs) in
// its own hidden app folder in your Google Drive ("appDataFolder", scope drive.appdata: the app can't see or change
// any of your other Drive files, and they don't show in Drive's file list).
//
// Connect (once per device): POST /api/google/connect opens Google's sign-in page in the browser; Google sends the
// browser back to a one-time address on this computer (http://127.0.0.1:<port>), which hands the app a code; the
// app trades it for a refresh token (OAuth 2.0 for installed apps, with PKCE). The token is kept in
// data/sync/google.json on this device only (never exported). POST /api/google/disconnect forgets and revokes it.
//
// The OAuth client (a "Desktop app" in Google Cloud) is built in from google-client.json (build.rs). Without that
// file the app is built without Google Drive and the Sync panel doesn't offer it.

use crate::util::*;
use base64::Engine;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const CLIENT_ID: Option<&str> = option_env!("OSRS_GOOGLE_CLIENT_ID");
const CLIENT_SECRET: Option<&str> = option_env!("OSRS_GOOGLE_CLIENT_SECRET");
const SCOPE: &str = "https://www.googleapis.com/auth/drive.appdata";
const AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const FILES_URL: &str = "https://www.googleapis.com/drive/v3/files";
const UPLOAD_URL: &str = "https://www.googleapis.com/upload/drive/v3/files";
const WAIT: Duration = Duration::from_secs(300); // how long the sign-in page may take

// The sign-in that is running: None = none; Some("") = waiting for the browser; Some(msg) = it failed with msg
static CONNECT: Mutex<Option<String>> = Mutex::new(None);
// The current access token (an hour) and when it runs out
static ACCESS: Mutex<Option<(String, Instant)>> = Mutex::new(None);

pub fn available() -> bool {
    CLIENT_ID.is_some() && CLIENT_SECRET.is_some()
}
fn client() -> (&'static str, &'static str) {
    (CLIENT_ID.unwrap_or_default(), CLIENT_SECRET.unwrap_or_default())
}
fn token_file(data: &Path) -> PathBuf {
    data.join("sync").join("google.json")
}
fn refresh_token(data: &Path) -> Option<String> {
    let v: Value = serde_json::from_str(trim(&read_text(&token_file(data))?)).ok()?;
    v.get("refresh_token").and_then(|t| t.as_str()).filter(|t| !t.is_empty()).map(str::to_string)
}
pub fn connected(data: &Path) -> bool {
    available() && refresh_token(data).is_some()
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(Duration::from_secs(60)).build()
}
// A request's answer as text; an HTTP error -> "<code>: <body>"
fn answer(r: Result<ureq::Response, ureq::Error>) -> Result<String, String> {
    match r {
        Ok(res) => res.into_string().map_err(|e| e.to_string()),
        Err(ureq::Error::Status(code, res)) => Err(format!("{code}: {}", res.into_string().unwrap_or_default())),
        Err(e) => Err(format!("no connection to Google ({e})")),
    }
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}
fn random(n: usize) -> String {
    let mut buf = vec![0u8; n];
    getrandom::getrandom(&mut buf).expect("no random numbers from the system");
    b64(&buf)
}
fn query_param(q: &str, name: &str) -> Option<String> {
    q.split('&').find_map(|kv| {
        let (k, v) = kv.split_once('=')?;
        (k == name).then(|| percent_encoding::percent_decode_str(&v.replace('+', " ")).decode_utf8_lossy().into_owned())
    })
}
fn enc(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

// The system browser (the app's own window can't do Google's sign-in)
fn open_browser(url: &str) {
    let r = if cfg!(target_os = "macos") {
        std::process::Command::new("open").arg(url).spawn()
    } else if cfg!(windows) {
        // rundll32, not "cmd /c start": cmd would cut the address at the first "&"
        std::process::Command::new("rundll32").args(["url.dll,FileProtocolHandler", url]).spawn()
    } else {
        std::process::Command::new("xdg-open").arg(url).spawn()
    };
    if let Err(e) = r {
        eprintln!("Google Drive: could not open the browser ({e}); open this address yourself: {url}");
    }
}

// POST /api/google/connect -> {"url"} (the sign-in page, also opened in the browser)
pub fn start_connect(data: &Path) -> (u16, String) {
    if !available() {
        return (400, r#"{"error":"This build of the app has no Google Drive sign-in."}"#.into());
    }
    let listener = match TcpListener::bind("127.0.0.1:0") {
        Ok(l) => l,
        Err(e) => return (500, format!(r#"{{"error":{}}}"#, ps_str(&format!("Could not start the sign-in: {e}")))),
    };
    let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
    let redirect = format!("http://127.0.0.1:{port}");
    let verifier = random(48);
    let challenge = b64(&Sha256::digest(verifier.as_bytes()));
    let state = random(16);
    let url = format!(
        "{AUTH_URL}?client_id={}&redirect_uri={}&response_type=code&scope={}&code_challenge={challenge}&code_challenge_method=S256&state={state}&access_type=offline&prompt=consent",
        enc(client().0),
        enc(&redirect),
        enc(SCOPE)
    );
    *CONNECT.lock().unwrap() = Some(String::new());
    let data = data.to_path_buf();
    std::thread::spawn(move || {
        let r = wait_for_code(listener, &state).and_then(|code| exchange(&data, &code, &verifier, &redirect));
        let mut c = CONNECT.lock().unwrap();
        match r {
            Ok(()) => {
                *c = None;
                eprintln!("Google Drive: connected");
            }
            Err(e) => {
                eprintln!("Google Drive: sign-in failed: {e}");
                *c = Some(e);
            }
        }
    });
    open_browser(&url);
    (200, ps_json(&json!({"url": url})))
}

// The browser comes back to http://127.0.0.1:<port>/?code=...&state=... (or ?error=access_denied)
fn wait_for_code(listener: TcpListener, state: &str) -> Result<String, String> {
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    let started = Instant::now();
    loop {
        if started.elapsed() > WAIT {
            return Err("The sign-in took too long. Try Connect again.".into());
        }
        let (mut stream, _) = match listener.accept() {
            Ok(s) => s,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(200));
                continue;
            }
            Err(e) => return Err(e.to_string()),
        };
        let _ = stream.set_nonblocking(false);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
        let mut line = String::new();
        let _ = BufReader::new(&stream).read_line(&mut line);
        // "GET /?code=...&state=... HTTP/1.1"; anything else (the browser asking for /favicon.ico) is ignored
        let target = line.split_whitespace().nth(1).unwrap_or("");
        let query = target.split_once('?').map(|(_, q)| q).unwrap_or("");
        let code = query_param(query, "code");
        let err = query_param(query, "error");
        if code.is_none() && err.is_none() {
            let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            continue;
        }
        let ok = code.is_some() && query_param(query, "state").as_deref() == Some(state);
        let msg = if ok {
            "OSRS Dashboard is connected to Google Drive. You can close this tab."
        } else {
            "Google Drive was not connected. You can close this tab and try again from the dashboard."
        };
        let page = format!(
            "<!doctype html><meta charset=utf-8><title>OSRS Dashboard</title><body style=\"font:16px system-ui;padding:40px;background:#111;color:#eee\"><p>{msg}</p>"
        );
        let _ = stream.write_all(
            format!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}", page.len())
                .as_bytes(),
        );
        if let Some(e) = err {
            return Err(if e == "access_denied" { "You didn't allow access in the browser.".into() } else { format!("Google said: {e}") });
        }
        if !ok {
            return Err("The sign-in answer didn't match. Try Connect again.".into());
        }
        return Ok(code.unwrap());
    }
}

fn exchange(data: &Path, code: &str, verifier: &str, redirect: &str) -> Result<(), String> {
    let (id, secret) = client();
    let body = answer(agent().post(TOKEN_URL).send_form(&[
        ("client_id", id),
        ("client_secret", secret),
        ("code", code),
        ("code_verifier", verifier),
        ("redirect_uri", redirect),
        ("grant_type", "authorization_code"),
    ]))?;
    let v: Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    let rt = v.get("refresh_token").and_then(|t| t.as_str()).ok_or("Google sent no refresh token")?;
    ensure_dir(&data.join("sync"));
    write_text(&token_file(data), &ps_json(&json!({"refresh_token": rt, "connected": iso(now())}))).map_err(|e| e.to_string())?;
    if let (Some(at), Some(exp)) = (v.get("access_token").and_then(|t| t.as_str()), v.get("expires_in").and_then(|t| t.as_u64())) {
        *ACCESS.lock().unwrap() = Some((at.to_string(), Instant::now() + Duration::from_secs(exp.saturating_sub(60))));
    }
    Ok(())
}

// POST /api/google/disconnect
pub fn disconnect(data: &Path) -> (u16, String) {
    if let Some(rt) = refresh_token(data) {
        let _ = agent().post("https://oauth2.googleapis.com/revoke").send_form(&[("token", rt.as_str())]);
    }
    let _ = std::fs::remove_file(token_file(data));
    *ACCESS.lock().unwrap() = None;
    (200, r#"{"ok":true}"#.into())
}

// For the Sync panel: {"available","connected","connecting","error"}
pub fn status(data: &Path) -> Value {
    let c = CONNECT.lock().unwrap().clone();
    json!({
        "available": available(),
        "connected": connected(data),
        "connecting": c.as_deref() == Some(""),
        "error": c.filter(|e| !e.is_empty())
    })
}

fn access_token(data: &Path) -> Result<String, String> {
    if let Some((t, until)) = ACCESS.lock().unwrap().clone() {
        if Instant::now() < until {
            return Ok(t);
        }
    }
    let rt = refresh_token(data).ok_or("Google Drive isn't connected")?;
    let (id, secret) = client();
    let r = answer(agent().post(TOKEN_URL).send_form(&[
        ("client_id", id),
        ("client_secret", secret),
        ("refresh_token", rt.as_str()),
        ("grant_type", "refresh_token"),
    ]));
    let body = match r {
        Ok(b) => b,
        Err(e) if e.contains("invalid_grant") => {
            // Revoked in the Google account, or expired: connect again
            let _ = std::fs::remove_file(token_file(data));
            return Err("Google Drive access ended (revoked or expired). Connect again in the Sync panel.".into());
        }
        Err(e) => return Err(e),
    };
    let v: Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    let at = v.get("access_token").and_then(|t| t.as_str()).ok_or("Google sent no access token")?.to_string();
    let exp = v.get("expires_in").and_then(|t| t.as_u64()).unwrap_or(3600);
    *ACCESS.lock().unwrap() = Some((at.clone(), Instant::now() + Duration::from_secs(exp.saturating_sub(60))));
    Ok(at)
}

pub struct DriveFile {
    pub id: String,
    pub name: String,
    pub props: Value, // appProperties: player, device, name, exported (so a file is only downloaded when newer)
}

// The sync files in the app folder
pub fn list(data: &Path) -> Result<Vec<DriveFile>, String> {
    let at = access_token(data)?;
    let url = format!("{FILES_URL}?spaces=appDataFolder&pageSize=1000&fields={}", enc("files(id,name,appProperties)"));
    let body = answer(agent().get(&url).set("Authorization", &format!("Bearer {at}")).call())?;
    let v: Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    Ok(v.get("files")
        .and_then(|f| f.as_array())
        .map(|a| {
            a.iter()
                .map(|f| DriveFile {
                    id: ps_string(f.get("id")),
                    name: ps_string(f.get("name")),
                    props: f.get("appProperties").cloned().unwrap_or(Value::Null),
                })
                .collect()
        })
        .unwrap_or_default())
}

pub fn download(data: &Path, id: &str) -> Result<String, String> {
    let at = access_token(data)?;
    answer(agent().get(&format!("{FILES_URL}/{}?alt=media", enc(id))).set("Authorization", &format!("Bearer {at}")).call())
}

// Creates or replaces the file `name` in the app folder
pub fn upload(data: &Path, name: &str, text: &str, props: Value) -> Result<(), String> {
    let at = access_token(data)?;
    let existing = list(data)?.into_iter().find(|f| f.name == name).map(|f| f.id);
    let boundary = format!("osrs{}", random(12).replace(['-', '_'], "x"));
    let meta = match &existing {
        Some(_) => json!({"appProperties": props}),
        None => json!({"name": name, "parents": ["appDataFolder"], "appProperties": props}),
    };
    let body = format!(
        "--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{}\r\n--{boundary}\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n{text}\r\n--{boundary}--\r\n",
        meta
    );
    let req = match &existing {
        Some(id) => agent().request("PATCH", &format!("{UPLOAD_URL}/{}?uploadType=multipart", enc(id))),
        None => agent().post(&format!("{UPLOAD_URL}?uploadType=multipart")),
    };
    answer(
        req.set("Authorization", &format!("Bearer {at}"))
            .set("Content-Type", &format!("multipart/related; boundary={boundary}"))
            .send_string(&body),
    )
    .map(|_| ())
}
