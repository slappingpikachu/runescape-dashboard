#!/usr/bin/env python3
# Two-computer sync test for the app, on COPIES of a dashboard data folder (the real one is only read).
# Two "computers" play on the two days after the newest RuneLite file (3 Vorkath, then 2 Zulrah), then sync, and the
# test checks that both end up with the same history, the collection log counts each drop once, the drop log has no
# false "played without the plugin" gaps, a second import changes nothing, and an Update afterwards keeps the newer
# data.
#
#   python3 tools/sync-test.py <app binary> [synced|unsynced] [--root <data folder>] [--plugin <plugin folder>]
#   AUTO=1 ...   sync through a shared folder with real Updates (/api/refresh, needs the internet for the hiscores)
#   synced = both RuneLites share Loot Tracker totals (the same RuneLite account), the usual case
# The binary: app/src-tauri/target/release/osrs-dashboard (cargo build --release). The data folder needs an OSRS
# name in settings.json and some history; the plugin folder its four .json files (defaults: this computer's).
# The expected counts assume the player doesn't own the Jar of decay (22106) or Snakeling pet (12921) yet.
import json, os, shutil, subprocess, sys, glob, copy, tempfile, platform
from datetime import datetime, timedelta

args = sys.argv[1:]
def opt(name, default):
    if name in args:
        i = args.index(name); v = args[i + 1]; del args[i:i + 2]; return v
    return default
appdata = os.path.expanduser("~/Library/Application Support/OSRS Dashboard") if platform.system() == "Darwin" else os.path.join(os.environ.get("APPDATA", ""), "OSRS Dashboard")
REAL_ROOT = opt("--root", appdata)
PLAYER = json.load(open(os.path.join(REAL_ROOT, "settings.json"), encoding="utf-8-sig"))["player"]
slug = "".join(c if c.isalnum() or c in "_-" else "_" for c in PLAYER.replace(" ", " ").strip().lower())
REAL_PLUG = opt("--plugin", os.path.expanduser(os.path.join("~", ".runelite", "plugin-data", "osrsdatasync", slug)))
BIN = args[0]
MODE = args[1] if len(args) > 1 else "synced"
W = os.path.join(tempfile.gettempdir(), "osrs-sync-test-" + MODE)
# The two play days come after everything already there: the newest RuneLite file and the newest saved history line
_times = [json.load(open(os.path.join(REAL_PLUG, f), encoding="utf-8"))["updated"][:10] for f in ("progress.json", "killcounts.json", "containers.json", "clog.json")]
for _f in ("history.jsonl", "bank/history.jsonl", "clog/history.jsonl", "progress/history.jsonl", "plugin/kills-history.jsonl"):
    _p = os.path.join(REAL_ROOT, "data", _f)
    if os.path.exists(_p):
        for _l in open(_p, encoding="utf-8"):
            if _l.startswith('{"t":"'): _times.append(_l[6:16])
newest = max(_times)
# Everything the test makes is newer than this (full times): the checks below only look at those lines
_full = []
for _f in ("history.jsonl", "plugin/kills-history.jsonl", "plugin/loot-gaps.jsonl"):
    _p = os.path.join(REAL_ROOT, "data", _f)
    if os.path.exists(_p):
        _full += [_l[6:_l.index('"', 6)] for _l in open(_p, encoding="utf-8") if _l.startswith('{"t":"')]
CUTOFF = max(_full) if _full else ""
DAY1 = (datetime.fromisoformat(newest) + timedelta(days=1)).strftime("%Y-%m-%d")
DAY2 = (datetime.fromisoformat(newest) + timedelta(days=2)).strftime("%Y-%m-%d")
problems = []

_start = json.load(open(os.path.join(REAL_PLUG, "clog.json"), encoding="utf-8"))["items"]
WANT = {"21907": _start.get("21907", 0) + 1, "22106": _start.get("22106", 0) + 1, "12921": _start.get("12921", 0) + 1, "2996": _start.get("2996", 0) + 6}
def bad(msg): problems.append(msg); print("  PROBLEM:", msg)

if os.path.exists(W): shutil.rmtree(W)
os.makedirs(W)

def setup(dev):
    root = os.path.join(W, dev, "root"); plug = os.path.join(W, dev, "plugins", slug); dl = os.path.join(W, dev, "Downloads")
    shutil.copytree(REAL_ROOT, root)
    shutil.rmtree(os.path.join(root, "data", "sync"), ignore_errors=True)
    shutil.copytree(REAL_PLUG, plug); os.makedirs(dl)
    for f in glob.glob(os.path.join(plug, "loot.jsonl")): os.remove(f)   # each drop log starts empty
    # The drop log gap check starts fresh here (its saved starting point belongs to the copied computer's RuneLite)
    for f in ("loot-base.json",):
        if os.path.exists(os.path.join(root, "data", "plugin", f)): os.remove(os.path.join(root, "data", "plugin", f))
    # RuneLite's files are at least as new as the saved history (as on the computer you play on): its Loot Tracker
    # totals never below the last kill totals line
    kh = [l for l in open(os.path.join(root, "data", "plugin", "kills-history.jsonl"), encoding="utf-8") if l.strip()] if os.path.exists(os.path.join(root, "data", "plugin", "kills-history.jsonl")) else []
    if kh:
        kc_path = os.path.join(plug, "killcounts.json"); kc = json.load(open(kc_path, encoding="utf-8"))
        for key, n in json.loads(kh[-1])["k"].items():
            ty, name = key.split("|", 1)
            e = kc["lootTracker"].setdefault(ty, {}).setdefault(name, {"kills": 0, "first": 0, "last": 0, "drops": {}})
            e["kills"] = max(e["kills"], n)
        json.dump(kc, open(kc_path, "w", encoding="utf-8"), separators=(",", ":"))
    return {"name": dev, "root": root, "plug": plug, "dl": dl}

def run(dev, *args, body=None):
    env = dict(os.environ, OSRS_PLUGIN_ROOT=os.path.dirname(dev["plug"]), OSRS_SYNC_EXPORT_DIR=dev["dl"],
               COMPUTERNAME=dev["name"])   # device name
    cmd = [BIN, "--root", dev["root"]] + list(args)
    r = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout.strip(), r.stderr.strip()

def refresh(dev, t):
    out = []
    for step in ["progress", "lootgaps", "clog", "bank", "kills"]:
        a = ["--step", step] + ([t] if step == "kills" else [])
        rc, so, se = run(dev, *a)
        out.append(f"{step}: {so}")
        if rc: bad(f"{dev['name']} refresh {step} failed: {so} {se}")
    return out

def rd(path):
    with open(path, encoding="utf-8") as f: return json.load(f)
def wr(path, o):
    with open(path, "w", encoding="utf-8") as f: json.dump(o, f, separators=(",", ":"))
def lines(path):
    if not os.path.exists(path): return []
    return [l.strip() for l in open(path, encoding="utf-8") if l.strip()]
def ms(iso):
    from datetime import datetime; return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)

# ---- play on a device: change its plugin files the way the plugin would ----
def play(dev, day, quests, clog_new, clog_more, kills, other_kills, gp):
    p = dev["plug"]; t = f"{day}T18:00:00.000000Z"
    pr = rd(f"{p}/progress.json"); pr["updated"] = t; 
    for quest in quests: pr["quests"][quest] = 2
    pr["questPoints"] += len(quests); wr(f"{p}/progress.json", pr)
    c = rd(f"{p}/clog.json"); c["updated"] = t
    for i in clog_new: c["items"][str(i)] = 1
    for i, n in clog_more.items(): c["items"][str(i)] = c["items"].get(str(i), 0) + n
    c["obtained"] = len([v for v in c["items"].values() if v > 0]); wr(f"{p}/clog.json", c)
    k = rd(f"{p}/killcounts.json"); k["updated"] = t
    with open(f"{p}/loot.jsonl", "a", encoding="utf-8") as f:
        for i, (src, drops) in enumerate(kills):
            lt = f"{day}T17:{10 + i:02d}:00.000Z"
            f.write(json.dumps({"t": lt, "source": src, "type": "NPC", "value": 1000, "items": [[d, 1, 500] for d in drops]}, separators=(",", ":")) + "\n")
    for src, drops, lt in [(s, d, f"{day}T17:{10 + i:02d}:00.000Z") for i, (s, d) in enumerate(kills)] + other_kills:
        e = k["lootTracker"].setdefault("NPC", {}).setdefault(src, {"kills": 0, "first": ms(lt), "last": 0, "drops": {}})
        e["kills"] += 1; e["last"] = max(e["last"], ms(lt))
        for d in drops: e["drops"][str(d)] = e["drops"].get(str(d), 0) + 1
    wr(f"{p}/killcounts.json", k)
    ct = rd(f"{p}/containers.json"); ct["updated"] = t; ct["bankAt"] = ms(t)
    for it in ct["bank"]:
        if it[0] == 995: it[1] += gp
    wr(f"{p}/containers.json", ct)
    # a hiscores snapshot of that day (offline the hiscores aren't asked: copy the last line with a new time); a real
    # Update (AUTO) takes its own
    h = [] if AUTO else lines(f"{dev['root']}/data/history.jsonl"); last = json.loads(h[-1]) if h else None
    if h: last["t"] = f"{day}T18:05:00.0000000Z"
    if h:
        with open(f"{dev['root']}/data/history.jsonl", "a", encoding="utf-8") as f: f.write(json.dumps(last, separators=(",", ":")) + "\n")
    if AUTO:   # a real Update: merge the other device's file, Refresh (hiscores online), save this device's file
        rc, so, se = run(dev, "--cli", "POST", "/api/refresh")
        if rc: bad(f"{dev['name']} Update failed: {so[:200]} {se[-300:]}")
        return [l for l in se.splitlines() if "sync" in l.lower() or "Drop log" in l or "skipped" in l]
    return refresh(dev, f"{day}T18:05:00.0000000Z")

A = setup("DESKTOP"); B = setup("MACBOOK")
AUTO = os.environ.get("AUTO") == "1"
SHARED = os.path.join(W, "GoogleDrive", "OSRS Dashboard Sync"); os.makedirs(SHARED)
if AUTO:
    for d in (A, B):
        rc, so, se = run(d, "--cli", "POST", "/api/sync-folder", json.dumps({"folder": SHARED}))
        if rc: bad("sync-folder failed: " + so)
VORK = [(("Vorkath"), [21907]), ("Vorkath", []), ("Vorkath", [22106])]   # head + jar of decay (log items)
ZUL = [("Zulrah", [12921]), ("Zulrah", [])]                                # pet snakeling (log item)
synced = MODE == "synced"
print(f"== desktop plays {DAY1} (3 Vorkath)")
for l in play(A, DAY1, ["Bear Your Soul"], [], {}, VORK, [], 1_000_000): print("  ", l)
print(f"== mac plays {DAY2} (2 Zulrah)" + (" — its Loot Tracker also shows the desktop's 3 Vorkath" if synced else ""))
other = [(s, d, f"{DAY1}T17:{10 + i:02d}:00.000Z") for i, (s, d) in enumerate(VORK)] if synced else []
for l in play(B, DAY2, ["Bear Your Soul", "Mage Arena I"], [], {"2996": 6}, ZUL, other, 1_000_000 + 2_000_000): print("  ", l)

def export(dev):
    rc, so, se = run(dev, "--cli", "POST", "/api/export")
    if rc: bad(f"export on {dev['name']} failed: {so}")
    print(f"  export {dev['name']}: {json.loads(so).get('message')}")
    f = sorted(glob.glob(os.path.join(dev["dl"], "*.osrssync")))[-1]; return f
def imp(dev, f):
    rc, so, se = run(dev, "--cli", "POST", "/api/import", "@" + f)
    msg = json.loads(so).get("message") or json.loads(so).get("error")
    print(f"  import on {dev['name']}: {msg}")
    if rc: bad(f"import on {dev['name']} failed: {msg}")
    return msg

print("== sync both ways")
if AUTO:
    print("  files in the shared folder:", sorted(os.listdir(SHARED)))
    rc, so, se = run(A, "--cli", "POST", "/api/autosync"); print("  desktop opens the dashboard:", so)
    rc, so, se = run(B, "--cli", "POST", "/api/autosync"); print("  mac opens the dashboard:", so)
    st = json.loads(run(A, "--cli", "GET", "/api/sync")[1]); print("  desktop Sync panel:", {k: st[k] for k in ("folder", "autoExported", "others", "autoError")})
    fa = glob.glob(SHARED + "/*DESKTOP*")[0]; fb = glob.glob(SHARED + "/*MACBOOK*")[0]
else:
    fa = export(A); imp(B, fa)
    fb = export(B); imp(A, fb)
print("== import the same files again (must change nothing)")
snap = {d["name"]: {p: open(p, "rb").read() for p in glob.glob(d["root"] + "/data/**/*.json*", recursive=True) if "/sync/" not in p} for d in (A, B)}
m1 = imp(B, fa); m2 = imp(A, fb)
for d in (A, B):
    for p, b in snap[d["name"]].items():
        if open(p, "rb").read() != b: bad(f"re-import changed {os.path.relpath(p, d['root'])} on {d['name']}")
for m in (m1, m2):
    if not m.startswith("Already up to date"): bad(f"re-import said: {m}")

print("== both devices should now hold the same history")
for rel in ["data/history.jsonl", "data/bank/history.jsonl", "data/progress/history.jsonl", "data/plugin/kills-history.jsonl", "data/progress/latest.json"]:
    a, b = lines(f"{A['root']}/{rel}"), lines(f"{B['root']}/{rel}")
    print(f"  {rel}: desktop {len(a)} lines, mac {len(b)} lines, {'same' if a == b else 'DIFFERENT'}")
    if a != b: bad(f"{rel} differs between devices")

def clog_last(dev):
    return json.loads(lines(f"{dev['root']}/data/clog/history.jsonl")[-1])["items"]
for d in (A, B):
    it = clog_last(d)
    want = WANT
    got = {k: (it.get(k) or [0])[0] for k in WANT}
    print(f"  clog on {d['name']}: {got} (want {want})")
    if got != want: bad(f"clog on {d['name']} is {got}, expected {want}")

lt = json.loads(lines(f"{A['root']}/data/progress/latest.json")[0]) if os.path.exists(f"{A['root']}/data/progress/latest.json") else {}
for d in (A, B):
    l = rd(f"{d['root']}/data/progress/latest.json")
    q = {k: l.get("quests", {}).get(k) for k in ["Bear Your Soul", "Mage Arena I"]}
    print(f"  quests on {d['name']}: {q}")

print("== drop log / kills shown by each dashboard")
for d in (A, B):
    rc, so, se = run(d, "--cli", "GET", "/api/plugin")
    o = json.loads(so)
    drops = o.get("drops") or o.get("loot") or []
    gaps = [x for x in drops if isinstance(x, dict) and x.get("gap") and x.get("source") in ("Vorkath", "Zulrah") and x.get("t", "") > CUTOFF]
    real = [x for x in drops if isinstance(x, dict) and not x.get("gap") and x.get("source") in ("Vorkath", "Zulrah")]
    print(f"  {d['name']}: {len(real)} real Vorkath/Zulrah kills, gaps: {[(g['source'], g['kills']) for g in gaps]}")
    if len(real) != 5: bad(f"{d['name']} drop log shows {len(real)} of the 5 kills")
    if gaps: bad(f"{d['name']} still shows 'played without the plugin' gaps: {[(g['source'], g['kills']) for g in gaps]}")

print("== Update again on each device WITHOUT playing (desktop's RuneLite files are now older than the Mac's)")
for d in (A, B):
    for l in refresh(d, (datetime.fromisoformat(DAY2) + timedelta(days=1)).strftime("%Y-%m-%dT09:00:00.0000000Z")): print(f"   {d['name']} {l}")
for d in (A, B):
    it = clog_last(d); got = {k: (it.get(k) or [0])[0] for k in WANT}
    if got != WANT: bad(f"after Update, clog on {d['name']} is {got}")
    l = rd(f"{d['root']}/data/progress/latest.json")
    if l.get("quests", {}).get("Mage Arena I") != 2: bad(f"after Update, {d['name']} lost the Mac's quest")
    b = json.loads(lines(f"{d['root']}/data/bank/history.jsonl")[-1])
    print(f"   {d['name']} newest bank save: saved {b.get('saved')}")
kh = lines(f"{A['root']}/data/plugin/kills-history.jsonl")
print("== kills the feed shows for the new days (counted over the highest total so far, like app.js killGainsByRefresh)")
top = dict(json.loads(kh[0])["k"]); gains = {}
for l in kh[1:]:
    o = json.loads(l)
    for key, n in o["k"].items():
        g = n - top.get(key, 0)
        if g > 0:
            if o["t"] > CUTOFF and key in ("NPC|Vorkath", "NPC|Zulrah"): gains[key] = gains.get(key, 0) + g
            top[key] = n
print("  ", gains)
if gains != {"NPC|Vorkath": 3, "NPC|Zulrah": 2}: bad(f"the kills feed would show {gains}, expected 3 Vorkath and 2 Zulrah")

print("\nRESULT:", "all good" if not problems else f"{len(problems)} problem(s)")
for p in problems: print(" -", p)
