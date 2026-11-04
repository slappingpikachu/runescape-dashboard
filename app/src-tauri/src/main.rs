// OSRS Dashboard desktop app (Tauri). The window shows the same page as the PowerShell version (index.html, app.js,
// styles.css); every request it makes ("/api/history", "/icons/...") is answered by server.rs through the app's own
// "dash" protocol, so there is no network port and no console window. Where the page and the data are: layout.rs.
//
// Without a window (tests, tools): see cli.rs.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod bank;
mod cli;
mod clog;
mod icons;
mod layout;
mod net;
mod plugin;
mod refresh;
mod server;
mod util;
mod wom;

use tauri::{WebviewUrl, WebviewWindowBuilder};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let layout = layout::find(&args);
    if let Some(code) = cli::run(&args, &layout) {
        std::process::exit(code);
    }
    let dash = std::sync::Arc::new(server::Dashboard::new(&layout));
    let handler = dash.clone();

    tauri::Builder::default()
        .register_asynchronous_uri_scheme_protocol("dash", move |_ctx, request, responder| {
            let d = handler.clone();
            // Off the UI thread: big answers (history, bank) and Refresh never freeze the window
            std::thread::spawn(move || responder.respond(d.handle(&request)));
        })
        .setup(|app| {
            // Windows' web view reaches custom protocols as http://<name>.localhost, Mac's as <name>://localhost
            #[cfg(windows)]
            let url = "http://dash.localhost/";
            #[cfg(not(windows))]
            let url = "dash://localhost/";
            WebviewWindowBuilder::new(app, "main", WebviewUrl::CustomProtocol(url.parse().unwrap()))
                .title("OSRS Dashboard")
                .inner_size(1600.0, 1000.0)
                .min_inner_size(420.0, 500.0)
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running the OSRS Dashboard app");
}
