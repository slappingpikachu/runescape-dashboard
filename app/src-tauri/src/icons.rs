// Pictures: downloaded from the OSRS Wiki once, given a 1px white outline (icon-outline.ps1), saved in icons\<kind>\
// and served from disk after that. icons\no-picture.txt lists pictures the wiki doesn't have (404), never asked again.

use crate::net::{Web, UA};
use crate::util::{append_text, ensure_dir, escape_data};
use image::{imageops, ImageFormat, Rgba, RgbaImage};
use std::collections::HashSet;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

// Adds a 1px white outline around a picture: a white silhouette drawn at the 8 positions around it, then the picture
// on top (like the GDI+ drawing in icon-outline.ps1). Returns PNG bytes.
pub fn add_outline(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let src = image::load_from_memory(bytes).map_err(|e| e.to_string())?.to_rgba8();
    Ok(png(&outline(&src)))
}

fn over(dst: &mut Rgba<u8>, s: [f32; 4]) {
    let sa = s[3] / 255.0;
    if sa <= 0.0 {
        return;
    }
    let da = dst[3] as f32 / 255.0;
    let oa = sa + da * (1.0 - sa);
    let mut out = [0u8; 4];
    for i in 0..3 {
        let c = (s[i] * sa + dst[i] as f32 * da * (1.0 - sa)) / oa;
        out[i] = c.round().clamp(0.0, 255.0) as u8;
    }
    out[3] = (oa * 255.0).round().clamp(0.0, 255.0) as u8;
    *dst = Rgba(out);
}

fn outline(src: &RgbaImage) -> RgbaImage {
    let (w, h) = src.dimensions();
    let mut out = RgbaImage::new(w + 2, h + 2);
    for dx in 0..3u32 {
        for dy in 0..3u32 {
            if dx == 1 && dy == 1 {
                continue;
            }
            for (x, y, p) in src.enumerate_pixels() {
                over(out.get_pixel_mut(x + dx, y + dy), [255.0, 255.0, 255.0, p[3] as f32]);
            }
        }
    }
    for (x, y, p) in src.enumerate_pixels() {
        over(out.get_pixel_mut(x + 1, y + 1), [p[0] as f32, p[1] as f32, p[2] as f32, p[3] as f32]);
    }
    out
}

fn png(img: &RgbaImage) -> Vec<u8> {
    let mut c = Cursor::new(Vec::new());
    let _ = img.write_to(&mut c, ImageFormat::Png);
    c.into_inner()
}

// Monster pictures: shrunk to fit 64 px (never enlarged), then outlined
pub fn shrink_outline(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let src = image::load_from_memory(bytes).map_err(|e| e.to_string())?.to_rgba8();
    let (sw, sh) = src.dimensions();
    let scale = (64.0 / sw.max(sh) as f64).min(1.0);
    // [int] in PowerShell rounds half to even
    let w = ((sw as f64 * scale).round_ties_even() as u32).max(1);
    let h = ((sh as f64 * scale).round_ties_even() as u32).max(1);
    let small = if (w, h) == (sw, sh) { src } else { imageops::resize(&src, w, h, imageops::FilterType::CatmullRom) };
    Ok(png(&outline(&small)))
}

// "Special:Redirect/file" follows renamed wiki files
pub fn wiki_file_url(file: &str) -> String {
    format!("https://oldschool.runescape.wiki/w/Special:Redirect/file/{}", escape_data(&file.replace(' ', "_")))
}

pub struct Icons {
    // The data folder's icons\ (new pictures are saved here)
    pub dir: PathBuf,
    // The installer's pictures (installed app only): used when the data folder has no copy
    bundled: Option<PathBuf>,
    no_icon: Mutex<HashSet<String>>,
}

impl Icons {
    pub fn new(root: &Path, bundled: Option<PathBuf>) -> Icons {
        let dir = root.join("icons");
        let mut set = HashSet::new();
        for d in std::iter::once(&dir).chain(bundled.as_ref()) {
            for l in crate::util::read_lines(&d.join("no-picture.txt")) {
                if !l.is_empty() {
                    set.insert(l);
                }
            }
        }
        Icons { dir, bundled, no_icon: Mutex::new(set) }
    }

    // icons\<kind>\<file>, from the data folder or else the installer's copy
    pub fn path_of(&self, kind: &str, file: &str) -> Option<PathBuf> {
        std::iter::once(&self.dir).chain(self.bundled.as_ref()).map(|d| d.join(kind).join(file)).find(|p| p.is_file())
    }
    pub fn read(&self, kind: &str, file: &str) -> Option<Vec<u8>> {
        std::fs::read(self.path_of(kind, file)?).ok()
    }
    pub fn has(&self, kind: &str, file: &str) -> bool {
        self.path_of(kind, file).is_some()
    }
    // Every picture file name of a kind (both places)
    pub fn list(&self, kind: &str) -> Vec<String> {
        let mut names: Vec<String> = Vec::new();
        for d in std::iter::once(&self.dir).chain(self.bundled.as_ref()) {
            if let Ok(rd) = std::fs::read_dir(d.join(kind)) {
                names.extend(rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()));
            }
        }
        names.sort();
        names.dedup();
        names
    }

    pub fn known_missing(&self, key: &str) -> bool {
        self.no_icon.lock().unwrap().contains(key)
    }
    pub fn mark_trying(&self, key: &str) {
        self.no_icon.lock().unwrap().insert(key.to_string());
    }
    pub fn unmark(&self, key: &str) {
        self.no_icon.lock().unwrap().remove(key);
    }
    // A failed download: the wiki has no such picture (404) -> remembered for good; anything else -> this run only
    pub fn add_missing(&self, key: &str, status: u16) {
        self.no_icon.lock().unwrap().insert(key.to_string());
        if status == 404 {
            let _ = append_text(&self.dir.join("no-picture.txt"), &format!("{key}\r\n"));
        }
    }

    // icons\skill\<name>.png ("<name>_icon.png" on the wiki) and icons\wiki\<name>.png
    pub fn get_wiki(&self, web: &Web, kind: &str, name: &str) -> Option<Vec<u8>> {
        if let Some(b) = self.read(kind, &format!("{name}.png")) {
            return Some(b);
        }
        let dir = self.dir.join(kind);
        let file = dir.join(format!("{name}.png"));
        let key = format!("{kind}/{name}");
        if self.known_missing(&key) {
            return None;
        }
        let wiki = if kind == "skill" { format!("{name}_icon.png") } else { format!("{name}.png") };
        let got = web.fetch(&wiki_file_url(&wiki), UA);
        let Some(body) = got.body.filter(|_| (200..300).contains(&got.status)) else {
            self.add_missing(&key, got.status);
            return None;
        };
        let bytes = add_outline(&body).ok()?;
        ensure_dir(&dir);
        let _ = std::fs::write(&file, &bytes);
        Some(bytes)
    }

    // icons\item\<id>.png: the wiki file comes from clog images.json, else the bank's items.json
    pub fn get_item(&self, web: &Web, data_dir: &Path, id: &str) -> Option<Vec<u8>> {
        if let Some(b) = self.read("item", &format!("{id}.png")) {
            return Some(b);
        }
        let dir = self.dir.join("item");
        let file = dir.join(format!("{id}.png"));
        let key = format!("item/{id}");
        // Tried once per run: a missing icon isn't retried on every page load
        if self.known_missing(&key) {
            return None;
        }
        self.mark_trying(&key);
        let images = crate::util::read_json(&data_dir.join("clog").join("images.json"));
        let mut name = images.as_ref().and_then(|m| m.get(id)).map(|v| crate::util::ps_string(Some(v))).unwrap_or_default();
        if name.is_empty() {
            name = crate::bank::bank_image(data_dir, id).unwrap_or_default();
        }
        if name.is_empty() {
            return None;
        }
        let got = web.fetch(&wiki_file_url(&name), UA);
        let Some(body) = got.body.filter(|_| (200..300).contains(&got.status)) else {
            self.add_missing(&key, got.status);
            return None;
        };
        self.unmark(&key);
        let bytes = add_outline(&body).ok()?;
        ensure_dir(&dir);
        let _ = std::fs::write(&file, &bytes);
        Some(bytes)
    }
}
