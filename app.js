// OSRS progress dashboard. Data comes from the official hiscores via server.ps1,
// which only contacts the hiscores when "Update" is pressed.
// Each refresh is stored as a snapshot; gains = latest snapshot minus the
// snapshot in effect at the start of the selected period.

const WIKI = "/icons/wiki/"; // icons are cached locally by server.ps1
// Main words capitalised everywhere on the dashboard: "Tormented demon" -> "Tormented Demon".
// Small joining words stay lower case after the first word; tags like "(i)" and "(u)" are left alone.
const TITLE_SMALL = /^(of|the|and|in|at|to|a|an|on|for|or|by|vs|per|from|with)$/i;
const titleCase = (s) => String(s ?? "").replace(/\S+/g, (w, at) => at && TITLE_SMALL.test(w) ? w.toLowerCase()
  : /^\(\w\)$|^&/.test(w) ? w : w.replace(/^([^A-Za-z]*)([a-z])/, (m, p, c) => p + c.toUpperCase()));
const titleCached = new Map();
const titled = (s) => { let t = titleCached.get(s); if (t == null) titleCached.set(s, (t = titleCase(s))); return t; };
const COOLDOWN_S = 60;
const CLUE_TIERS = [
  { key: "beginner", color: "#a3a3a3" },
  { key: "easy",     color: "#4ade80" },
  { key: "medium",   color: "#38bdf8" },
  { key: "hard",     color: "#c084fc" },
  { key: "elite",    color: "#facc15" },
  { key: "master",   color: "#f87171" },
];

// XP required for each level (index = level), from the in-game formula
const XP_TABLE = (() => {
  const t = [0, 0];
  let pts = 0;
  for (let lvl = 1; lvl < 126; lvl++) {
    pts += Math.floor(lvl + 300 * Math.pow(2, lvl / 7));
    t[lvl + 1] = Math.floor(pts / 4);
  }
  return t;
})();
const MAX_XP = 200_000_000;

const state = {
  history: [],
  period: "day",
  chartMode: "total",
  skillSort: "game",
  bossSort: "most",
  selected: "Overall",
  bossQuery: "",
  feedFilter: "all",
  series: [], // what the chart compares: [{ kind: "skill"|"boss"|"clue"|"clog"|"item", name, color }] (item: name = id)
  detailItem: null, // collection log item id shown in the detail card (last selected skill/item was an item)
  modeBeforeSel: null, // chart mode to go back to when the selection that forced "Per Day" is cleared
  pick: null, // clicked bar in the "Per Day" chart: { key: bucket start ms, unit }
  bars: null, // { points, unit } of the current "Per Day" chart
  chart: null,
  cooldownUntil: 0,
};

const $ = (id) => document.getElementById(id);
const pos = (n) => Math.max(0, n ?? 0);
const clogOf = (snap) => snap.clog || state.clogFloor; // see setHistory
const fmt = (n) => (n == null || n < 0 ? "–" : Math.round(n).toLocaleString());
// One formatter, made once: building an Intl formatter per call cost ~35 ms per period click (bank lists call this
// thousands of times)
const COMPACT_FMT = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
const compact = (n) => COMPACT_FMT.format(n);
// Same for dates in hot loops (chart labels, heatmap, feed): fmtDate(d, opts) = d.toLocaleString(undefined, opts) for
// opts that name their fields, with each formatter made once
const DATE_FMTS = new Map();
const fmtDate = (d, opts) => {
  const key = JSON.stringify(opts);
  let f = DATE_FMTS.get(key);
  if (!f) DATE_FMTS.set(key, (f = new Intl.DateTimeFormat(undefined, opts)));
  return f.format(d);
};
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
// The phone snapshot (toolsbuild-snapshot.ps1) embeds the icons; icon() swaps the path for it
const icon = (path) => window.SNAPSHOT_ICONS?.[path] ?? path;
const wikiIcon = (file) => icon(WIKI + file);
const skillIcon = (name) => (name === "Overall" ? wikiIcon("Stats_icon.png") : icon(`/icons/skill/${name}.png`));
// Boss and clue tier icons, all from the OSRS Wiki. Most bosses
// have "<hiscores name> icon.png"; the rest are listed here by slug (lowercase, letters and digits only).
const GAME_ICON_WIKI = {
  cluescrollsall: "Clue_scroll.png", cluescrollsbeginner: "Clue_scroll_(beginner).png", cluescrollseasy: "Clue_scroll_(easy).png",
  cluescrollsmedium: "Clue_scroll_(medium).png", cluescrollshard: "Clue_scroll_(hard).png", cluescrollselite: "Clue_scroll_(elite).png",
  cluescrollsmaster: "Clue_scroll_(master).png",
  artio: "Callisto_icon.png", calvarion: "Vet'ion_icon.png", spindel: "Venenatis_icon.png", barrowschests: "Barrows_Brothers_icon.png",
  brutus: "Brutus_Boss_icon.png", chambersofxeric: "Great_Olm_icon.png", chambersofxericchallengemode: "Chambers_of_Xeric_Challenge_Mode_icon.png",
  kreearra: "Kree'arra_icon.png", lunarchests: "Blood_Moon_icon.png", mimic: "The_Mimic_icon.png", nightmare: "The_Nightmare_icon.png",
  phosanisnightmare: "The_Nightmare_icon.png", thegauntlet: "Crystalline_Hunllef_icon.png", thecorruptedgauntlet: "Corrupted_Hunllef_icon.png",
  theatreofblood: "Verzik_Vitur_icon.png", theatreofbloodhardmode: "Verzik_Vitur_icon.png", thermonuclearsmokedevil: "Thermonuclear_smoke_devil_icon.png",
  tombsofamascut: "Tombs_of_Amascut_-_Normal_Mode_icon.png", tombsofamascutexpertmode: "Tombs_of_Amascut_-_Expert_Mode_icon.png",
};
const gameIcon = (name) => wikiIcon(GAME_ICON_WIKI[name.toLowerCase().replace(/[^a-z0-9]/g, "")] ?? `${name.replace(/ /g, "_")}_icon.png`);

// Attributes + <img> for a boss icon; falls back to initials if the wiki has no icon
function bossIconHtml(name) {
  const initials = name.replace(/^The /, "").split(/[\s:'-]+/).filter((w) => /^[A-Z0-9]/.test(w)).map((w) => w[0]).join("").slice(0, 2);
  return `data-initials="${esc(initials)}"><img src="${gameIcon(name)}" alt="" loading="lazy">`;
}
document.addEventListener("error", (e) => {
  const holder = e.target.tagName === "IMG" && e.target.parentElement;
  if (holder?.dataset.initials) holder.textContent = holder.dataset.initials;
}, true);

// ---------- data ----------

function normalize(raw) {
  const skills = {};
  for (const s of raw.d.skills) skills[s.name] = { level: s.level, xp: pos(s.xp), rank: s.rank };

  const acts = raw.d.activities;
  const bossStart = acts.findIndex((a) => a.name === "Collections Logged") + 1;
  const bosses = {};
  const clues = {};
  acts.forEach((a, i) => {
    const m = a.name.match(/^Clue Scrolls \((\w+)\)$/);
    if (m) clues[m[1]] = pos(a.score);
    else if (bossStart > 0 && i >= bossStart) bosses[a.name] = pos(a.score);
  });
  // Collection log slots (0 while the hiscores still list it as unranked)
  const clog = pos(acts.find((a) => a.name === "Collections Logged")?.score);
  const rifts = pos(acts.find((a) => a.name === "Rifts closed")?.score); // Guardians of the Rift
  return { time: new Date(raw.t), name: raw.d.name, skills, bosses, clues, clog, rifts };
}

// Full names of the periods (the buttons in the top bar show short ones: 1D, 1W, MTD, YTD, 1Y, ...)
const PERIOD_NAMES = { day: "Today", "2d": "Last 2 Days", "3d": "Last 3 Days", "1w": "1 Week", "2w": "2 Weeks", month: "This Month", "1m": "1 Month", "2m": "2 Months", "3m": "3 Months",
  "6m": "6 Months", year: "This Year", "1y": "1 Year", "2y": "2 Years", "3y": "3 Years", "4y": "4 Years", "5y": "5 Years", all: "All Time" };
const periodLabel = (p = state.period) => PERIOD_NAMES[p] ?? p;

// Days follow the game's daily reset (00:00 UTC), not local midnight: "Today" = since the last
// reset, and every period, day bar, heatmap cell and day heading runs reset to reset. A day is named by its UTC
// date (GAME_DAY in date formats); times of day stay local.
const GAME_DAY = { timeZone: "UTC" };
function periodStart(period) {
  const now = new Date(), y = now.getUTCFullYear(), m = now.getUTCMonth(), d = now.getUTCDate();
  const at = (yy, mm, dd) => new Date(Date.UTC(yy, mm, dd));
  if (period === "day") return at(y, m, d);
  if (period === "month") return at(y, m, 1);
  const days = period.match(/^(\d+)d$/); // "2d", "3d": today plus the days before it, from their reset
  if (days) return at(y, m, d - Number(days[1]) + 1);
  const weeks = period.match(/^(\d+)w$/); // "2w": that many weeks back from today's reset
  if (weeks) return at(y, m, d - 7 * Number(weeks[1]));
  const back = period.match(/^(\d+)m$/); // "1m", "2m", "3m", "6m": that many months back from today's reset
  if (back) return at(y, m - Number(back[1]), d);
  if (period === "year") return at(y, 0, 1);
  const years = period.match(/^(\d+)y$/); // "1y" ... "5y": that many years back from today's reset
  if (years) return at(y - Number(years[1]), m, d);
  return new Date(0);
}
// Start of the small graphs (bank, collection log slots + value): the selected period, but never before the
// data begins (dataStart). "All Time" = from the first data point.
const graphStart = (dataStart, period = state.period) => new Date(Math.max(+periodStart(period), +dataStart));

// ---- Own period per section: the Bank and Collection log cards have an "Own Period" switch at
// the top right. On: the card shows its own period picker and stops following the top bar's period. Off: back to
// the top bar's. state.secPeriods = { bank: "1w", clog: null, ... } (remembered on this device).
const secPeriod = (sec) => state.secPeriods?.[sec] ?? state.period;
const secOwn = (sec) => state.secPeriods?.[sec] != null;
// The render context (start, baseline snapshot) for a section's period
function secCtx(sec, c) {
  const period = secPeriod(sec);
  if (period === state.period) return { ...c, period };
  const start = periodStart(period), bi = baselineIndex(start);
  return { ...c, period, start, bi, base: state.history[bi] };
}
const PIN_IC = `<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="5" width="18" height="16" rx="2.5"/><path d="M3 10h18M8 3v4M16 3v4"/></svg>`;
const CHEV_IC = `<svg class="sec-chev" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6"/></svg>`;
// The picker is a small panel floating over the card (opens from the button, closes on a pick,
// a click outside or Esc), not a row that pushes the card down. Which section's panel is open: secOpen.
let secOpen = null;
const periodShort = (p) => $("periods").querySelector(`[data-period="${p}"]`)?.textContent ?? p;
function secPeriodBtnHtml(sec) {
  const on = secOwn(sec), open = secOpen === sec;
  const btn = `<button type="button" class="sec-pin ${on ? "active" : ""} ${open ? "open" : ""}" data-sec-pin="${sec}"
    aria-expanded="${open}" aria-haspopup="true" title="${on ? "This section uses its own period" : "Give this section its own period (it stops following the one at the top)"}">${PIN_IC}<span>Own Period</span>${on ? `<b>${esc(periodShort(secPeriod(sec)))}</b>` : ""}${CHEV_IC}</button>`;
  return `<span class="sec-pop-wrap" data-sec-wrap="${sec}">${btn}${open ? secPopHtml(sec) : ""}</span>`;
}
// The panel: an on/off switch, then the top bar's periods in its groups (split at its dividers)
function secPopHtml(sec) {
  const on = secOwn(sec), p = secPeriod(sec);
  const groups = [[]];
  for (const el of $("periods").children) {
    if (el.classList.contains("seg-sep")) groups.push([]);
    else if (el.dataset.period) groups.at(-1).push(el);
  }
  const names = ["Days & weeks", "Months", "Years", "Everything"];
  const rows = groups.map((g, i) => `<div class="sec-pop-group"><span>${names[i] ?? ""}</span><div>${g.map((el) =>
    `<button type="button" data-sec-period="${el.dataset.period}" class="${on && el.dataset.period === p ? "active" : ""}" title="${esc(el.title)}">${esc(el.textContent)}</button>`).join("")}</div></div>`).join("");
  return `<div class="sec-pop" role="dialog" aria-label="Period for this section" data-sec="${sec}">
    <button type="button" class="sec-pop-switch" data-sec-toggle role="switch" aria-checked="${on}">
      <span class="sec-pop-label"><b>Own Period</b></span>
      <span class="sec-switch ${on ? "on" : ""}"><i></i></span></button>
    <div class="sec-pop-groups">${rows}</div></div>`;
}
function secRedraw(sec, periodChanged) {
  if (sec === "bank") { // only the button and the period parts: the item list keeps its scroll
    $("bank-pin").innerHTML = secPeriodBtnHtml("bank");
    if (periodChanged) renderBankPeriod(ctx());
  } else if (periodChanged) renderClog(ctx());
  else { const w = document.querySelector(`[data-sec-wrap="${sec}"]`); if (w) w.outerHTML = secPeriodBtnHtml(sec); }
}
function secClose() { const s = secOpen; if (s) { secOpen = null; secRedraw(s, false); } }
document.addEventListener("click", (e) => {
  const wrap = e.target.closest("[data-sec-wrap]");
  if (!wrap) return secClose(); // a click anywhere else closes an open panel
  const sec = wrap.dataset.secWrap;
  const set = (v) => { state.secPeriods = { ...(state.secPeriods ?? {}), [sec]: v }; savePrefs(); };
  if (e.target.closest("[data-sec-pin]")) { secOpen = secOpen === sec ? null : sec; return secRedraw(sec, false); }
  if (e.target.closest("[data-sec-toggle]")) { // off -> on starts at the top bar's period; the panel stays open
    set(secOwn(sec) ? null : state.period); return secRedraw(sec, true);
  }
  const pick = e.target.closest("[data-sec-period]");
  if (pick) { set(pick.dataset.secPeriod); secOpen = null; secRedraw(sec, true); }
});
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && secOpen) secClose(); });
// Axis dates: add the year when it isn't this year (long periods)
const axisDate = (d) => d.toLocaleDateString(undefined, { ...GAME_DAY, month: "short", day: "numeric", ...(d.getUTCFullYear() !== new Date().getUTCFullYear() ? { year: "numeric" } : {}) });

// The snapshot representing your stats at the start of the period: the last one
// taken before it, or the very first one if tracking began later.
function baselineIndex(start) {
  let idx = 0;
  state.history.forEach((s, i) => { if (s.time <= start) idx = i; });
  return idx;
}

function combatLevel(s) {
  const L = (n) => s[n]?.level ?? 1;
  const base = 0.25 * (L("Defence") + L("Hitpoints") + Math.floor(L("Prayer") / 2));
  const melee = 0.325 * (L("Attack") + L("Strength"));
  const range = 0.325 * Math.floor(L("Ranged") * 1.5);
  const mage = 0.325 * Math.floor(L("Magic") * 1.5);
  return Math.floor(base + Math.max(melee, range, mage));
}

function levelProgress(xp) {
  let lvl = 1;
  while (lvl < 99 && xp >= XP_TABLE[lvl + 1]) lvl++;
  if (lvl >= 99) return { lvl, pct: Math.min(1, xp / MAX_XP), toNext: Math.max(0, MAX_XP - xp), nextLabel: "200M" };
  const lo = XP_TABLE[lvl], hi = XP_TABLE[lvl + 1];
  return { lvl, pct: (xp - lo) / (hi - lo), toNext: hi - xp, nextLabel: `Lvl ${lvl + 1}` };
}

// ---------- server ----------

async function loadHistory() {
  const [res] = await Promise.all([fetch("/api/history", { cache: "no-cache" }), loadClog()]);
  if (!res.ok) throw new Error("Could not load saved history.");
  setHistory(await res.json());
}

// Collection log items and quests/diaries/combat tasks (from the OSRS Data Sync plugin), saved by the server on
// Refresh. Both optional.
async function loadClog() {
  const get = async (url) => {
    try { const res = await fetch(url, { cache: "no-cache" }); return res.ok ? await res.json() : null; } catch { return null; }
  };
  [state.clogRaw, state.progress, state.diaryInfo, state.miniquests, state.questReqs, state.caInfo, state.caHistory, state.bankRaw, state.plugin] = await Promise.all([get("/api/clog"), get("/api/progress"),
    state.diaryInfo ?? get("/api/diary-tasks"), state.miniquests ?? get("/api/miniquests"), state.questReqs ?? get("/api/quest-reqs"), state.caInfo ?? get("/api/ca-tasks"), get("/api/ca-history"), get("/api/bank"), get("/api/plugin")]);
}

function setHistory(raw) {
  state.history = raw.map(normalize).sort((a, b) => a.time - b.time);
  // The hiscores only show the collection log once it is ranked. Before that, use the first
  // ranked count so the day it first appears isn't counted as hundreds of new slots.
  const first = state.history.find((s) => s.clog > 0);
  state.clogSince = first?.time ?? null;
  state.clogFloor = first?.clog ?? 0;
  setClog(state.clogRaw);
  setBank(state.bankRaw); // after setClog: log item prices fill in for bank items without one
  state.killSrc = null; // kills & loot, rebuilt from state.plugin on first use (after setBank: prices)
  state.killLog = null; // drop log, same
  state.npcIcons = null;
  state.activity = null; // rebuilt once, on first use
  state.clogRecent = null; // collection log "Recent updates", same
  render();
  renderData();
}

async function refresh() {
  const btn = $("refresh-btn");
  btn.disabled = true;
  btn.classList.add("loading");
  $("refresh-label").textContent = "Updating…";
  const before = state.history.at(-1);
  try {
    const res = await fetch("/api/refresh", { method: "POST", body: "{}" });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) {
      const wait = Number((body.error || "").match(/(\d+)s/)?.[1]);
      if (wait) state.cooldownUntil = Date.now() + wait * 1000;
      throw new Error(body.error || `Update failed (${res.status})`);
    }
    state.cooldownUntil = Date.now() + COOLDOWN_S * 1000;
    await loadClog(); // the same refresh also updated the collection log
    setHistory(body);
    const after = state.history.at(-1);
    const gained = before ? after.skills.Overall.xp - before.skills.Overall.xp : 0;
    toast(gained > 0 ? `Stats updated · +${gained.toLocaleString()} XP since last update` : "Stats updated · no change since last update", "success");
  } catch (e) {
    toast(e.message, "error");
  } finally {
    btn.classList.remove("loading");
    tickCooldown();
  }
}

function tickCooldown() {
  const btn = $("refresh-btn");
  if (!btn) return; // phone snapshot has no refresh button
  const left = Math.ceil((state.cooldownUntil - Date.now()) / 1000);
  if (left > 0) {
    btn.disabled = true;
    $("refresh-label").textContent = `Ready in ${left}s`;
    setTimeout(tickCooldown, 1000);
  } else {
    btn.disabled = location.protocol === "file:";
    $("refresh-label").textContent = "Update";
  }
}

let toastTimer;
function toast(msg, kind = "") {
  const el = $("toast");
  el.textContent = msg;
  el.className = "toast " + kind;
  el.hidden = false;
  el.style.animation = "none"; el.offsetHeight; el.style.animation = "";
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.hidden = true), 4000);
}

// ---------- rendering ----------

function ctx() {
  const h = state.history;
  const cur = h.at(-1);
  const start = periodStart(state.period);
  const bi = baselineIndex(start);
  return { h, cur, base: h[bi], bi, start };
}

function render() {
  const h = state.history;
  $("empty").hidden = h.length > 0 || state.needsSetup;
  $("dashboard").hidden = h.length === 0;
  if (!h.length) return;

  const c = ctx();
  renderHeader(c);
  renderNote(c);
  renderTiles(c);
  renderSkills(c);
  renderDetail(c);
  renderBosses(c);
  renderClues(c);
  renderClog(c);
  renderBankPeriod(c);
  renderChart(c);
  if (state.killsView === "log") { state.killLogN = null; renderKillList(); } // the drop log follows the period
  moveIndicator();
  savePrefs();
}

// Parts that only change when new data arrives (not on period or selection clicks)
function renderData() {
  if (!state.history.length) return;
  renderHeader(ctx());
  renderClogItems();
  renderQuests();
  renderCa();
  renderBank();
  renderKills();
  syncNav();
  renderHeatmap();
  renderFeed();
}

// ---------- remembered view settings (this device only) ----------
const PREF_KEYS = ["period", "chartMode", "skillSort", "bossSort", "feedFilter", "clogGroup", "questFilter", "questKind", "caStatus", "caTier", "gpTab", "bankSort", "killsTab", "killsSort", "killsHidden", "killsView", "secPeriods"];
function savePrefs() {
  try { localStorage.setItem("osrs-dash-prefs", JSON.stringify(Object.fromEntries(PREF_KEYS.map((k) => [k, state[k]])))); } catch {}
}
function loadPrefs() {
  let p = {};
  try { p = JSON.parse(localStorage.getItem("osrs-dash-prefs") || "{}"); } catch {}
  const pick = (group, attr, key) => {
    const btn = p[key] != null && $(group)?.querySelector(`[${attr}="${CSS.escape(p[key])}"]`);
    if (btn) { state[key] = p[key]; setActive($(group), btn); }
  };
  pick("periods", "data-period", "period");
  pick("chart-mode", "data-mode", "chartMode");
  pick("skill-sort", "data-sort", "skillSort");
  pick("boss-sort", "data-sort", "bossSort");
  pick("feed-filter", "data-filter", "feedFilter");
  if (typeof p.clogGroup === "string") state.clogGroup = p.clogGroup;
  if (typeof p.questFilter === "string") state.questFilter = p.questFilter;
  if (typeof p.questKind === "string") state.questKind = p.questKind;
  if (typeof p.caStatus === "string") state.caStatus = p.caStatus;
  if (typeof p.caTier === "string" || p.caTier === null) state.caTier = p.caTier;
  if (["unit", "stack"].includes(p.gpTab)) state.gpTab = p.gpTab;
  if (["bank", "value", "name"].includes(p.bankSort)) state.bankSort = p.bankSort;
  if (typeof p.killsTab === "string") state.killsTab = p.killsTab;
  if (Array.isArray(p.killsHidden)) state.killsHidden = p.killsHidden.filter((k) => typeof k === "string");
  if (["kills", "value", "recent", "name"].includes(p.killsSort)) state.killsSort = p.killsSort;
  if (p.secPeriods && typeof p.secPeriods === "object") // only periods that still exist in the top picker
    state.secPeriods = Object.fromEntries(Object.entries(p.secPeriods).filter(([, v]) => v != null && v in PERIOD_NAMES));
  if (["sources", "log"].includes(p.killsView)) state.killsView = p.killsView;
}

function renderHeader({ cur }) {
  $("player-name").textContent = cur.name;
  const sk = cur.skills;
  $("player-chips").innerHTML = `
    <span class="chip"><img src="${wikiIcon("Combat_icon.png")}" alt="">Combat <b>${combatLevel(sk)}</b></span>
    <span class="chip"><img src="${wikiIcon("Stats_icon.png")}" alt="">Total <b>${fmt(sk.Overall.level)}</b></span>
    <span class="chip">XP <b>${compact(sk.Overall.xp)}</b></span>
    ${sk.Overall.rank > 0 ? `<span class="chip">Rank <b>#${fmt(sk.Overall.rank)}</b></span>` : ""}`;
  updateRelativeTime();
}

function updateRelativeTime() {
  const cur = state.history.at(-1);
  if (!cur) return;
  const mins = Math.round((Date.now() - cur.time) / 60000);
  const txt = mins < 1 ? "just now" : mins < 60 ? `${mins}m ago` : mins < 1440 ? `${Math.round(mins / 60)}h ago` : `${Math.round(mins / 1440)}d ago`;
  $("last-refresh").textContent = `Updated ${txt}`;
  $("last-refresh").title = cur.time.toLocaleString();
  $("refresh-btn").title = `Updated ${txt} (${cur.time.toLocaleString()})`; // the text hides on narrow screens
}

function renderNote({ h, base, start }) {
  const when = base.time.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  const note = h.length === 1 ? "First snapshot saved. Gains appear after your next update."
    : state.period === "all" ? `Since tracking began · ${when}`
    : base.time > start ? `Tracking began ${when}`
    : `Compared with ${when}`;
  $("period-note").innerHTML = `<b class="period-name">${esc(periodLabel())}</b><span>${esc(note)}</span>`;
}

function animateNumber(el, to, { prefix = "+", zero = "–" } = {}) {
  const from = Number(el.dataset.value || 0);
  el.dataset.value = to;
  el.classList.toggle("pos", to > 0);
  if (to <= 0) { el.textContent = zero; return; }
  const t0 = performance.now(), dur = 700;
  const step = (t) => {
    const p = Math.max(0, Math.min(1, (t - t0) / dur)); // rAF time can be slightly before t0
    const v = from + (to - from) * (1 - Math.pow(1 - p, 3));
    el.textContent = prefix + Math.round(v).toLocaleString();
    if (p < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

function skillGains({ cur, base }) {
  return Object.keys(cur.skills).filter((n) => n !== "Overall").map((name) => {
    const c = cur.skills[name], b = base.skills[name] || c;
    return { name, ...c, gain: c.xp - b.xp, levels: c.level - b.level };
  });
}

// Hiscores boss name -> Loot Tracker name, where they differ
const BOSS_LOOT_NAME = { "Barrows Chests": "Barrows", "The Gauntlet": "Crystalline Hunllef", "The Corrupted Gauntlet": "Corrupted Hunllef",
  "Lunar Chests": "Lunar Chest", "Grotesque Guardians": "Dusk" };
// Hiscores counts these differently from Loot Tracker loot claims, so every kill count shown is the hiscores one.
// Doom of Mokhaiotl: the hiscores count deep delves (each delve 8+ cleared); the Loot Tracker counts reward claims.
// Gauntlets: the Loot Tracker counts every reward chest, and losing to the Hunllef still gives one.
const BOSS_NO_LOOT_FALLBACK = new Set(["Doom of Mokhaiotl", "The Gauntlet", "Crystalline Hunllef", "The Corrupted Gauntlet", "Corrupted Hunllef"]);
const GAUNTLET_LOOT = new Set(["Crystalline Hunllef", "Corrupted Hunllef"]);
const CRYSTAL_SHARD = 23962; // in every Gauntlet chest from a win, never in one from a loss
const hiscoresKills = (name) => (BOSS_NO_LOOT_FALLBACK.has(name) ? state.history.at(-1)?.bosses?.[BOSS_LOOT_NAME_REV[name] ?? name] ?? 0 : null);
// Kills the plugin's Loot Tracker counted for a hiscores boss (0 if none)
function lootTrackerKills(name) {
  if (BOSS_NO_LOOT_FALLBACK.has(name)) return 0;
  const lt = state.plugin?.kills?.lootTracker ?? {}, n = BOSS_LOOT_NAME[name] ?? name;
  return lt.NPC?.[n]?.kills ?? lt.EVENT?.[n]?.kills ?? 0;
}

// Hiscores kill counts; a boss the hiscores show at 0 uses the Loot Tracker's count instead (fromLoot)
function bossGains({ cur, base }) {
  return Object.keys(cur.bosses).map((name) => {
    const hs = cur.bosses[name], lt = hs > 0 ? 0 : lootTrackerKills(name);
    return { name, total: hs || lt, fromLoot: lt > 0, gain: pos(hs - (base.bosses[name] ?? 0)) };
  });
}

function renderTiles(c) {
  const skills = skillGains(c);
  const trained = skills.filter((s) => s.gain > 0).sort((a, b) => b.gain - a.gain);
  const leveled = skills.filter((s) => s.levels > 0);
  const bosses = bossGains(c).filter((b) => b.gain > 0).sort((a, b) => b.gain - a.gain);
  const clueGain = pos(c.cur.clues.all - (c.base.clues.all ?? 0));

  animateNumber($("t-xp"), c.cur.skills.Overall.xp - c.base.skills.Overall.xp);
  animateNumber($("t-levels"), c.cur.skills.Overall.level - c.base.skills.Overall.level);
  animateNumber($("t-kills"), bosses.reduce((s, b) => s + b.gain, 0));
  animateNumber($("t-clues"), clueGain);

  $("t-xp-sub").textContent = trained.length ? `${trained.length} skill${trained.length > 1 ? "s" : ""} trained · top ${trained[0].name}` : "No XP gained yet";
  $("t-levels-sub").textContent = leveled.length ? leveled.map((s) => `${s.name} ${s.level}`).slice(0, 3).join(", ") : "No level-ups yet";
  $("t-kills-sub").textContent = bosses.length ? `Most: ${bosses[0].name} (+${bosses[0].gain})` : "No boss kills yet";
  const tiers = CLUE_TIERS.filter((t) => (c.cur.clues[t.key] ?? 0) > (c.base.clues[t.key] ?? 0)).map((t) => t.key);
  $("t-clues-sub").textContent = tiers.length ? tiers.join(", ") : clueGain ? "" : "No clues completed yet";
}

function renderSkills(c) {
  let skills = skillGains(c);
  if (state.skillSort === "gain") skills.sort((a, b) => b.gain - a.gain || b.xp - a.xp);
  if (state.skillSort === "level") skills.sort((a, b) => b.level - a.level || b.xp - a.xp);

  $("skills-grid").innerHTML = skills.map((s) => {
    const p = levelProgress(s.xp);
    return `<button class="skill ${isSel("skill", s.name) ? "selected" : ""} ${s.level >= 99 ? "maxed" : ""}" data-skill="${esc(s.name)}"
        data-xp="${s.xp}" data-tonext="${p.toNext}" data-next="${p.nextLabel}" data-pct="${p.pct}" data-rank="${s.rank}" data-gain="${s.gain}">
      <span class="skill-icon"><img src="${skillIcon(s.name)}" alt="" loading="lazy"></span>
      <span class="skill-name">${esc(s.name)}</span>
      <span class="skill-level">${s.level}<span class="skill-xp">${s.xp.toLocaleString()} xp</span></span>
      <span class="skill-foot">
        <span class="bar-track"><span class="bar-fill skill-bar" style="display:block;width:${(p.pct * 100).toFixed(1)}%;background-size:${p.pct > 0 ? (100 / p.pct).toFixed(1) : 100}% 100%"></span></span>
        ${s.gain > 0 ? `<span class="skill-gain">+${compact(s.gain)}</span>` : ""}
        ${s.levels > 0 ? `<span class="skill-up">▲${s.levels}</span>` : ""}
      </span>
    </button>`;
  }).join("");
}

function renderDetail(c) {
  if (state.detailItem && state.clog) return renderItemDetail(c, state.detailItem);
  const name = state.selected;
  const cur = c.cur.skills[name], base = c.base.skills[name] || cur;
  const isOverall = name === "Overall";
  const gain = cur.xp - base.xp;
  const levels = cur.level - base.level;

  let ring, rows;
  if (isOverall) {
    const maxTotal = Object.keys(c.cur.skills).length - 1;
    const pct = cur.level / (maxTotal * 99);
    ring = { pct, big: `${Math.round(pct * 100)}%`, small: "to max total" };
    const maxed = skillGains(c).filter((s) => s.level >= 99).length;
    rows = [
      ["Total Level", fmt(cur.level)],
      ["Total XP", fmt(cur.xp)],
      ["Skills at 99", `${maxed} / ${maxTotal}`],
      ["Rank", cur.rank > 0 ? "#" + fmt(cur.rank) : "–"],
    ];
  } else {
    const p = levelProgress(cur.xp);
    ring = { pct: p.pct, big: `${Math.floor(p.pct * 100)}%`, small: `to ${p.nextLabel}` };
    rows = [
      ["XP", fmt(cur.xp)],
      [`XP to ${p.nextLabel}`, fmt(p.toNext)],
      ["Rank", cur.rank > 0 ? "#" + fmt(cur.rank) : "–"],
    ];
  }
  rows.push(["XP Gained", gain > 0 ? "+" + fmt(gain) : "–", gain > 0]);
  if (levels > 0) rows.push(["Levels Gained", "+" + levels, true]);

  const R = 48, C = 2 * Math.PI * R;
  const to99 = !isOverall && cur.level < 99
    ? `<div class="progress-99">
         <div class="stat-row"><span>Progress to 99</span><b>${(cur.xp / XP_TABLE[99] * 100).toFixed(1)}%</b></div>
         <div class="bar-track"><div class="bar-fill" style="width:${(cur.xp / XP_TABLE[99] * 100).toFixed(1)}%"></div></div>
         <div class="muted small">${fmt(XP_TABLE[99] - cur.xp)} XP remaining</div>
       </div>` : "";

  const top = skillGains(c).filter((s) => s.gain > 0).sort((a, b) => b.gain - a.gain).slice(0, 5);
  const topMax = top[0]?.gain || 1;
  const topHtml = top.length
    ? top.map((s) => `<div class="gain-row" data-skill="${esc(s.name)}">
        <img src="${skillIcon(s.name)}" alt="">
        <div><div class="name">${esc(s.name)}</div><div class="bar-track"><div class="bar-fill green" style="width:${(s.gain / topMax * 100).toFixed(1)}%"></div></div></div>
        <b>+${compact(s.gain)}</b></div>`).join("")
    : `<p class="muted small" style="margin:0">Train a skill and press Update to see your top gains here.</p>`;

  $("detail").innerHTML = `
    <div class="detail-head">
      <div class="detail-icon"><img src="${skillIcon(name)}" alt=""></div>
      <div>
        <h3>${esc(name)}</h3>
        <div class="detail-level">${isOverall ? `Combat ${combatLevel(c.cur.skills)}` : `Level ${cur.level}${cur.level >= 99 ? " · Mastered" : ""}`}</div>
      </div>
      ${isOverall ? "" : `<button class="pill-toggle" id="back-overall" style="margin-left:auto;padding:5px 10px;font-size:13px;color:var(--text-2)">Overall</button>`}
    </div>
    <div class="ring-wrap">
      <div class="ring">
        <svg width="110" height="110" viewBox="0 0 110 110">
          <defs><linearGradient id="ringGrad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f6d27a"/><stop offset="1" stop-color="#e8b64c"/></linearGradient></defs>
          <circle class="ring-track" cx="55" cy="55" r="${R}" fill="none" stroke-width="9"/>
          <circle class="ring-fill" cx="55" cy="55" r="${R}" fill="none" stroke-width="9"
            stroke-dasharray="${C}" stroke-dashoffset="${C}" data-target="${C * (1 - ring.pct)}"/>
        </svg>
        <div class="ring-label"><b>${ring.big}</b><span>${ring.small}</span></div>
      </div>
      <div class="stat-list">
        ${rows.map(([k, v, g]) => `<div class="stat-row"><span>${k}</span><b class="${g ? "pos" : ""}">${v}</b></div>`).join("")}
      </div>
    </div>
    ${to99}
    <div class="top-gains"><h4>Top Gains This Period</h4>${topHtml}</div>`;

  requestAnimationFrame(() => {
    const f = $("detail").querySelector(".ring-fill");
    if (f) f.style.strokeDashoffset = f.dataset.target;
  });
}

const BOSS_SORTS = {
  most:  (a, b) => b.total - a.total,
  least: (a, b) => a.total - b.total,
  name:  (a, b) => a.name.replace(/^The /, "").localeCompare(b.name.replace(/^The /, "")),
};

// Every boss the hiscores list, killed or not, so unkilled bosses show too.
// 0 = never killed, or fewer kills than the hiscores need to list it; those rows are faded.
function renderBosses(c) {
  const all = bossGains(c);
  const killed = all.filter((b) => b.total > 0);
  const q = state.bossQuery.trim().toLowerCase();
  const list = all
    .filter((b) => !q || b.name.toLowerCase().includes(q))
    .sort((a, b) => BOSS_SORTS[state.bossSort](a, b) || BOSS_SORTS.name(a, b));
  const max = Math.max(1, ...all.map((b) => b.total));
  const totalKc = killed.reduce((s, b) => s + b.total, 0);
  $("boss-sub").textContent = `${killed.length} of ${all.length} bosses · ${totalKc.toLocaleString()} total kills`;

  $("boss-list").innerHTML = list.length
    ? list.map((b) => {
        const sel = isSel("boss", b.name);
        return `<div class="boss ${sel ? "selected" : ""} ${b.total ? "" : "none"}" data-boss="${esc(b.name)}" title="${b.fromLoot ? "Kill count from the Loot Tracker (not on the hiscores yet)" : `Show ${esc(b.name)} kills on the chart`}">
          <div class="boss-icon" ${bossIconHtml(b.name)}</div>
          <div>
            <div class="boss-name">${esc(b.name)}</div>
            <div class="bar-track"><div class="bar-fill" style="width:${(b.total / max * 100).toFixed(1)}%"></div></div>
          </div>
          <div class="boss-kc"><b>${b.total.toLocaleString()}</b>${b.gain > 0 ? `<span class="gain">+${b.gain}</span>` : ""}</div>
        </div>`;
      }).join("")
    : `<div class="boss-empty muted">${q ? "No bosses match your search." : "No boss kills yet."}</div>`;

}

function renderClues(c) {
  const total = c.cur.clues.all ?? 0;
  const gainAll = pos(total - (c.base.clues.all ?? 0));
  $("clue-sub").textContent = `${total.toLocaleString()} completed${gainAll ? ` · +${gainAll} this period` : ""}`;
  $("clue-grid").innerHTML = CLUE_TIERS.map(({ key, color }) => {
    const n = c.cur.clues[key] ?? 0;
    const g = pos(n - (c.base.clues[key] ?? 0));
    const label = key[0].toUpperCase() + key.slice(1);
    const sel = isSel("clue", key);
    return `<div class="clue ${n ? "" : "zero"} ${sel ? "selected" : ""}" data-clue="${key}" style="--tier:${color}" title="${label} clues: ${n} · click to chart">
      <img src="${gameIcon("cluescrolls" + key)}" alt="" loading="lazy">
      <div class="clue-name">${label}</div>
      <div class="clue-count">${n.toLocaleString()}</div>
      <div class="clue-gain">${g ? "+" + g : ""}</div>
    </div>`;
  }).join("");
}

// ---------- collection log ----------
// The official hiscores only publish how many slots are logged, not which items.

// ---------- small graph hover (collection log slots + value, bank value) ----------
// Each graph registers its nodes ({ x, t, value, d = change since the node before, null = first }) under
// data-spark. Hovering (or tapping, on phones) anywhere on the graph snaps to the nearest node and shows
// its time, value and change in the shared tooltip.
// opts.free (slots graph, too many changes to draw as dots): no dots; a marker follows the pointer along
// the line and the tooltip shows the date under the pointer and the value at that time.
const sparks = {};
const gpFull = (v) => Math.round(v).toLocaleString() + " GP";
const gpChange = (d) => (d > 0 ? "+" : "−") + compact(Math.abs(d)) + " GP";
function sparkNodesHtml(key, nodes, Y, H, opts) {
  sparks[key] = { nodes, Y, ...opts };
  const guide = `<line class="spark-guide" x1="0" x2="0" y1="0" y2="${H}" visibility="hidden"/>`;
  if (opts.free) return guide + `<circle class="spark-marker" r="3.5" fill="${opts.up}" stroke="#fff" stroke-width="2" visibility="hidden"/>`;
  return guide + nodes.map((n, i) =>
    `<circle data-node="${i}" cx="${n.x.toFixed(1)}" cy="${Y(n.value).toFixed(1)}" r="${n.d ? 3 : 2.2}" stroke="#12161e" stroke-width="1.5"
      fill="${n.d > 0 ? opts.up ?? "#4ade80" : n.d < 0 ? "#f87171" : "#8a93a5"}"/>`).join("");
}
let sparkOn = null; // the graph whose tooltip is showing
function sparkHover(e) {
  const svg = e.target.closest?.(".spark-hover");
  if (!svg && !sparkOn) return; // nothing showing and the pointer isn't on a graph: no work
  if (sparkOn) {
    sparkOn.querySelector("circle.on")?.classList.remove("on");
    for (const el of sparkOn.querySelectorAll(".spark-guide, .spark-marker")) el.setAttribute("visibility", "hidden");
  }
  const sp = svg && sparks[svg.dataset.spark];
  if (!sp?.nodes.length) { sparkOn = null; return placeTip(null); }
  if (!sparkOn) window.addEventListener("scroll", hideSparkTip, { once: true, passive: true });
  sparkOn = svg;
  const r = svg.getBoundingClientRect();
  const W = svg.viewBox.baseVal.width;
  const x = Math.min(W, Math.max(0, ((e.clientX - r.left) / r.width) * W));
  const guide = svg.querySelector(".spark-guide");
  guide.setAttribute("x1", x.toFixed(1));
  guide.setAttribute("x2", x.toFixed(1));
  guide.setAttribute("visibility", "visible");
  if (sp.free) {
    // The line runs straight between refreshes: put the marker on it; the value is the last refresh's
    const k = Math.max(0, sp.nodes.findLastIndex((n) => n.x <= x));
    const a = sp.nodes[k], b = sp.nodes[k + 1];
    const y = b && b.x > a.x ? sp.Y(a.value) + (sp.Y(b.value) - sp.Y(a.value)) * ((x - a.x) / (b.x - a.x)) : sp.Y(a.value);
    const marker = svg.querySelector(".spark-marker");
    marker.setAttribute("cx", x.toFixed(1));
    marker.setAttribute("cy", y.toFixed(1));
    marker.setAttribute("visibility", "visible");
    const t = new Date(+sp.nodes[0].t + (x / W) * (sp.t1 - sp.nodes[0].t));
    return placeTip(marker, `<div class="tip-title">${t.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" })}</div>
      <div class="tip-row"><span>${sp.label}</span><b>${sp.fmt(a.value)}</b></div>`);
  }
  guide.setAttribute("visibility", "hidden");
  let i = 0;
  sp.nodes.forEach((n, k) => { if (Math.abs(n.x - x) < Math.abs(sp.nodes[i].x - x)) i = k; });
  const n = sp.nodes[i], dot = svg.querySelector(`[data-node="${i}"]`);
  dot.classList.add("on");
  guide.setAttribute("x1", n.x.toFixed(1));
  guide.setAttribute("x2", n.x.toFixed(1));
  guide.setAttribute("visibility", "visible");
  const when = n.t.toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  const change = n.d == null ? `<span class="muted">${sp.first}</span>`
    : n.d ? `<b class="${n.d > 0 ? "pos" : "neg"}">${sp.fmtD(n.d)}</b>` : `<span class="muted">No change</span>`;
  placeTip(dot, `<div class="tip-title">${when}</div>
    <div class="tip-row"><span>${sp.label}</span><b>${sp.fmt(n.value)}</b></div>
    <div class="tip-row"><span>Change</span>${change}</div>`);
}
const hideSparkTip = () => sparkHover({ target: document.body });
for (const id of ["clog-card", "bank-card"]) {
  $(id).addEventListener("mousemove", sparkHover);
  $(id).addEventListener("click", sparkHover); // phones: tap a spot on a graph, tap elsewhere to close
  $(id).addEventListener("mouseleave", hideSparkTip);
}

function renderClog(c) {
  c = secCtx("clog", c); // its own period when "Own Period" is on
  const h = state.history;
  const card = $("clog-card");
  const sel = isSel("clog", "Collection log");
  const head = (sub) => `<div class="card-head">
      <div class="clog-head"><span class="clog-icon"><img src="${wikiIcon("Collection_log.png")}" alt=""></span>
        <div><h3>Collection Log</h3><p class="muted small">${sub}</p></div></div>
      ${state.clogSince ? `<div class="card-head-tools">${secPeriodBtnHtml("clog")}<button type="button" class="clog-chart-btn ${sel ? "active" : ""}" data-clog-chart aria-pressed="${sel}">${sel ? "On the chart ✓" : "Show on Chart"}</button></div>` : ""}
    </div>`;
  if (!state.clogSince) {
    card.innerHTML = head("Slots logged, from the official hiscores") +
      `<p class="muted small" style="margin:0">Your collection log shows up here once the hiscores list it. They only list it after you've logged enough slots.</p>`;
    return;
  }

  const now = clogOf(c.cur);
  const since = state.clogSince;
  const gainSince = (start) => pos(now - clogOf(h[baselineIndex(start)]));
  const daysAgo = (n) => new Date(dayKey(new Date()) - n * 86400e3);
  const periodGain = pos(now - clogOf(c.base));
  const pLabel = periodLabel(c.period);
  const weeks = Math.max(1, (Date.now() - since) / (7 * 86400e3));
  const perWeek = (now - state.clogFloor) / weeks;

  // New slots per day, only between two ranked snapshots
  const daily = new Map();
  for (let i = 1; i < h.length; i++) {
    if (!h[i - 1].clog) continue;
    const g = h[i].clog - h[i - 1].clog;
    if (g > 0) daily.set(dayKey(h[i].time), (daily.get(dayKey(h[i].time)) || 0) + g);
  }
  let bestKey = null;
  for (const [k, v] of daily) if (bestKey == null || v > daily.get(bestKey)) bestKey = k;
  const shortDate = (k, opts = { month: "short", day: "numeric" }) => new Date(k).toLocaleDateString(undefined, { ...GAME_DAY, ...opts });

  // Sparkline of slots logged over the last 3 months (or since tracking began, if later)
  const from = graphStart(since, c.period); // the selected period (not before tracking began)
  const pts = [[+from, clogOf(h[baselineIndex(from)])], ...h.filter((s) => s.time > from).map((s) => [+s.time, clogOf(s)])];
  const W = 300, H = 70, t0 = pts[0][0], t1 = Math.max(pts.at(-1)[0], t0 + 1);
  const lo = Math.min(...pts.map((p) => p[1])), hi = Math.max(lo + 1, ...pts.map((p) => p[1]));
  const X = (t) => ((t - t0) / (t1 - t0)) * W, Y = (v) => H - 4 - ((v - lo) / (hi - lo)) * (H - 10);
  const line = pts.map(([t, v]) => `${X(t).toFixed(1)},${Y(v).toFixed(1)}`).join(" ");
  // Hover: no dots (too many refreshes); the value under the pointer (sparkHover, free mode)
  const nodes = pts.map(([t, v]) => ({ x: X(t), t: new Date(t), value: v }));
  const spark = `<svg class="clog-spark spark-hover" data-spark="clog" viewBox="0 0 ${W} ${H}" role="img" aria-label="Slots logged over time, from ${lo} to ${hi}">
      <defs><linearGradient id="clogFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e8b64c" stop-opacity=".35"/><stop offset="1" stop-color="#e8b64c" stop-opacity="0"/></linearGradient></defs>
      <polygon points="0,${H} ${line} ${W},${H}" fill="url(#clogFill)"/>
      <polyline points="${line}" fill="none" stroke="#e8b64c" stroke-width="2" stroke-linejoin="round"/>
      <circle cx="${X(pts.at(-1)[0]).toFixed(1)}" cy="${Y(pts.at(-1)[1]).toFixed(1)}" r="3.5" fill="#e8b64c" stroke="#12161e" stroke-width="2"/>
      ${sparkNodesHtml("clog", nodes, Y, H, { label: "Slots Logged", up: "#e8b64c", free: true, t1, fmt: (v) => v.toLocaleString() })}
    </svg>`;

  const stats = [
    ["Last 7 Days", gainSince(daysAgo(7))],
    ["Last 30 Days", gainSince(daysAgo(30))],
    ["Per Week", perWeek, perWeek.toFixed(1)],
    ["Best Day", bestKey == null ? 0 : daily.get(bestKey), null, bestKey == null ? "" : shortDate(bestKey)],
  ].map(([k, v, shown, sub]) => `<div class="clog-stat"><span>${k}</span><b class="${v > 0 ? "pos" : ""}">${v > 0 ? "+" + (shown ?? v.toLocaleString()) : "–"}</b>${sub ? `<small>${sub}</small>` : ""}</div>`).join("");

  // "Recent updates" doesn't depend on the period: rebuilt only after new data (setHistory clears it) or when the
  // selected items change (they're marked in it). Saves ~10 ms on every period click.
  const selKey = state.series.filter((s) => s.kind === "item").map((s) => s.name).join(",");
  if (state.clogRecent?.selKey !== selKey) state.clogRecent = { selKey, v: ++clogRecentV, html: clogRecentHtml(daily, shortDate) };
  const { html: recent, v } = state.clogRecent;
  // Same list as on screen: keep its elements (re-creating its hundreds of tiles was most of this card's time)
  const oldList = card.querySelector(".clog-recent-list");
  const keep = oldList?.dataset.v === String(v) ? oldList : null;
  card.innerHTML = head(`Slots logged, from the official hiscores · tracked since ${since.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}`) + `
    <div class="clog-grid">
      <div class="clog-left"><div class="clog-hero">
        <div class="clog-count"><b>${now.toLocaleString()}</b><span>Slots Logged</span></div>
        <div class="clog-period ${periodGain ? "pos" : ""}">${periodGain ? "+" + periodGain : "No new slots"} <span>· ${esc(pLabel)}</span></div>
        ${spark}
        <div class="clog-axis"><span>${axisDate(from)} · ${lo}</span><span>Now · ${hi}</span></div>
      </div>
      <div class="clog-stats">${stats}</div>
      ${clogGpHtml(c, pLabel)}</div>
      <div class="clog-recent"><h4>Recent Updates</h4><div class="clog-recent-list" data-v="${v}">${keep ? "" : recent}</div></div>
    </div>`;
  if (keep) card.querySelector(".clog-recent-list").replaceWith(keep);
  // Keep the list where it was. The position comes from its scroll events: reading scrollTop here would force a
  // layout of the whole page in the middle of render()
  if (clogRecentScroll) card.querySelector(".clog-recent-list").scrollTop = clogRecentScroll;
}
let clogRecentV = 0; // version of state.clogRecent, to tell whether the list on screen is still the same
let clogRecentScroll = 0;
$("clog-card").addEventListener("scroll", (e) => {
  if (e.target.classList?.contains("clog-recent-list")) clogRecentScroll = e.target.scrollTop;
}, { capture: true, passive: true });

// Log page of a hiscores boss or Loot Tracker source ("Tormented Demon" -> tormented_demons)
function sourceCategory(name) {
  const c = bossCategory(BOSS_LOOT_NAME_REV[name] ?? name);
  if (c) return c;
  const k = slug(name);
  return state.clog.catIndex.has(k + "s") ? k + "s" : null;
}
const BOSS_LOOT_NAME_REV = Object.fromEntries(Object.entries(BOSS_LOOT_NAME).map(([hs, lt]) => [lt, hs]));

// What a day's logged items came from: hiscores bosses and clue tiers done that day, monsters/chests in the
// drop log that day, each only when its log page holds an item logged that day. g = kills / clues that day
// (0 = the source is known but its count that day isn't, e.g. before the drop log existed).
function clogSourcesForDay(k, end, logged) {
  const ins = bucketInsight(k, "day");
  const hasLogged = (c) => !!c && state.clog.catIndex.get(c)?.ids.some((id) => logged.has(id));
  const out = [], pages = new Set();
  for (const b of ins?.bosses ?? []) {
    const c = sourceCategory(b.name);
    if (hasLogged(c) && !pages.has(c)) { pages.add(c); out.push({ n: b.name, g: b.gain }); }
  }
  for (const x of ins?.clues ?? []) {
    if (clueCategories(x.key).some(hasLogged)) out.push({ n: `${titleCase(x.key)} Clues`, g: x.gain });
  }
  // Drop log (plugin): kills per source that day; counts if it dropped a logged item or its page has one
  const drops = new Map();
  for (const e of killLogEvents()) {
    if (e.t < k || e.t >= end || /clue scroll|casket/i.test(e.name)) continue;
    const d = drops.get(e.name) ?? { kills: 0, hit: false };
    d.kills += e.kills;
    d.hit ||= e.items.some(([id]) => logged.has(String(id)));
    drops.set(e.name, d);
  }
  for (const [name, d] of drops) {
    const c = sourceCategory(name);
    if (pages.has(c) || !(d.hit || hasLogged(c))) continue;
    if (c) pages.add(c);
    out.push({ n: titleCase(BOSS_LOOT_NAME_REV[name] ?? name), g: d.kills });
  }
  // Pages with a logged item but no count that day: name the monster if the Loot Tracker or hiscores know it
  const known = [...Object.keys(state.history.at(-1)?.bosses ?? {}),
    ...Object.values(state.plugin?.kills?.lootTracker ?? {}).flatMap((byName) => Object.keys(byName))];
  // (with its count when every Loot Tracker kill of it was that day)
  const ltKills = (name) => Object.values(state.plugin?.kills?.lootTracker ?? {})
    .map((byName) => byName[name]).filter((r) => r && r.first >= k && r.last < end.getTime() && !BOSS_NO_LOOT_FALLBACK.has(name)).reduce((t, r) => t + (r.kills ?? 0), 0);
  for (const name of known) {
    const c = sourceCategory(name);
    if (!c || pages.has(c) || clueTierOf(c) || !hasLogged(c)) continue;
    pages.add(c);
    out.push({ n: titleCase(BOSS_LOOT_NAME_REV[name] ?? name), g: ltKills(name) });
  }
  return out.sort((a, b) => b.g - a.g).slice(0, 4);
}

// Most recent days with collection log changes (new slots per day: daily), with what else happened that day
function clogRecentHtml(daily, shortDate) {
  // Duplicates and new items the slot count didn't cover, per day
  const extraByDay = new Map();
  for (const d of state.clog?.dupes ?? []) {
    if (!d.at) continue;
    const k = dayKey(d.at);
    extraByDay.set(k, [...(extraByDay.get(k) ?? []), d]);
  }
  const recentKeys = [...new Set([...daily.keys(), ...extraByDay.keys()])].sort((a, b) => b - a).slice(0, 30);
  return recentKeys.length ? recentKeys.map((k) => {
    const end = nextBucket(new Date(k), "day");
    const sessions = clogSessionsBetween(new Date(k), end);
    const logged = new Set([...sessions.flatMap((s) => s.items), ...(extraByDay.get(k) ?? []).map((d) => String(d.id))]);
    const same = logged.size ? clogSourcesForDay(k, end, logged) : [];
    return `<div class="clog-day">
        <div class="clog-date"><b>${shortDate(k)}</b><span>${shortDate(k, { weekday: "short" })}</span></div>
        <div class="clog-mid">
          ${same.length ? `<div class="clog-from">From: ${same.map((s) => `${esc(s.n)}${s.g ? ` <em>+${s.g.toLocaleString()}</em>` : ""}`).join(" · ")}</div>` : ""}
          ${clogItemsHtml(sessions, { compact: true })}
          ${clogExtrasHtml(extraByDay.get(k) ?? [])}
        </div>
        ${daily.get(k) ? `<b class="clog-plus" title="New slots">+${daily.get(k)}</b>` : ""}
      </div>`;
  }).join("") : `<p class="muted small" style="margin:0">No collection log changes recorded yet. Press Update after you log an item.</p>`;
}

// GE value of everything in the log (count obtained × today's GE price; untradeables count 0),
// at each saved sync. Built once per data load.
function clogGpSeries() {
  const cl = state.clog;
  if (!cl) return [];
  return (cl.gp ??= cl.lines.map((line) => {
    let v = 0;
    for (const [id, [count]] of Object.entries(line.items)) v += count * itemPrice(id);
    return { t: new Date(line.t), v };
  }));
}
function clogGpHtml(c, pLabelGp) {
  const all = clogGpSeries();
  if (!all.length) return "";
  const now = all.at(-1).v;
  const at = (time) => [...all].reverse().find((p) => p.t <= time) ?? all[0];
  // Graph window: the last 3 months, like the slots graph. Item counts only exist from the
  // first sync on, so before that the graph stays empty instead of guessing.
  const start = graphStart(all[0].t, c.period), late = all[0].t > start; // the selected period, from the first sync at the earliest
  const s = late ? all : [{ t: start, v: at(start).v }, ...all.filter((p) => p.t > start)];
  const gain = now - at(c.base.time).v;
  const fmtGp = (n) => compact(n) + " GP";

  // Step line: the value only changes at a sync
  const W = 300, H = 90, t0 = +start, t1 = Math.max(Date.now(), t0 + 1);
  const lo = Math.min(...s.map((p) => p.v)), hi = Math.max(lo + 1, now);
  const X = (t) => ((t - t0) / (t1 - t0)) * W, Y = (v) => H - 4 - ((v - lo) / (hi - lo)) * (H - 12);
  const pts = [];
  s.forEach((p, i) => { if (i) pts.push([X(+p.t), Y(s[i - 1].v)]); pts.push([X(+p.t), Y(p.v)]); });
  pts.push([W, Y(now)]);
  const line = pts.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const day = (d) => d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  // A node for every saved sync in the window (plus the window start)
  const nodes = s.map((p, i) => ({ x: X(+p.t), t: p.t, value: p.v, d: i ? p.v - s[i - 1].v : null }));
  const dots = sparkNodesHtml("clog-gp", nodes, Y, H, { label: "Log Value", first: late ? "First Sync" : "Start of the graph", fmt: gpFull, fmtD: gpChange });
  return `<div class="clog-gp">
      <div class="clog-gp-top">
        <div><span>Collection Log Value</span><b title="${now.toLocaleString()} GP">${fmtGp(now)}</b></div>
        <div class="clog-period ${gain > 0 ? "pos" : ""}">${gain > 0 ? "+" + fmtGp(gain) : "No new value"} <span>· ${esc(pLabelGp)}</span></div>
      </div>
      <svg class="clog-spark spark-hover" data-spark="clog-gp" viewBox="0 0 ${W} ${H}" role="img" aria-label="Collection log value over time, ${fmtGp(lo)} to ${fmtGp(now)}">
        <defs><linearGradient id="gpFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4ade80" stop-opacity=".3"/><stop offset="1" stop-color="#4ade80" stop-opacity="0"/></linearGradient></defs>
        <polygon points="${pts[0][0].toFixed(1)},${H} ${line} ${W},${H}" fill="url(#gpFill)"/>
        ${late ? `<line x1="${pts[0][0].toFixed(1)}" y1="0" x2="${pts[0][0].toFixed(1)}" y2="${H}" stroke="#5b6475" stroke-dasharray="3 3"/>
          <text x="${(pts[0][0] - 6).toFixed(1)}" y="${H - 8}" text-anchor="end" font-size="11" fill="#8a93a5">Value tracked from ${day(s[0].t)}</text>` : ""}
        <polyline points="${line}" fill="none" stroke="#4ade80" stroke-width="2" stroke-linejoin="round"/>
        ${dots}
      </svg>
      <div class="clog-axis"><span>${axisDate(start)}${late ? "" : ` · ${fmtGp(lo)}`}</span><span>Now · ${fmtGp(now)}</span></div>
      <p class="muted small clog-gp-note">Items obtained × today's GE price (OSRS Wiki) · untradeables count as 0</p>
      <div class="gp-top">
        <div class="gp-top-head"><h4>Most Valuable</h4>
          <div class="pill-toggle" id="gp-tabs">
            <button data-gp-tab="unit" class="${state.gpTab === "stack" ? "" : "active"}">Per Item</button>
            <button data-gp-tab="stack" class="${state.gpTab === "stack" ? "active" : ""}">Stack Total</button>
          </div></div>
        <ol class="gp-list">${gpTopRows()}</ol>
      </div>
    </div>`;
}
// Top 10 logged items by GE price of one item, or by the whole stack (count obtained × price)
function gpTopRows() {
  const cl = state.clog, stack = state.gpTab === "stack";
  const val = (id) => itemPrice(id) * (stack ? cl.owned.get(id).count : 1);
  const top = [...cl.owned.keys()].filter((id) => itemPrice(id) > 0).sort((a, b) => val(b) - val(a)).slice(0, 10);
  if (!top.length) return `<li class="muted small">No GE prices saved yet.</li>`;
  return top.map((id, i) => {
    const n = cl.owned.get(id).count;
    return `<li><button type="button" class="gp-row ${valueTier(id).cls} ${isSel("item", id) ? "sel" : ""}" data-item="${esc(id)}" title="Show ${esc(itemName(id))}">
      <span class="gp-rank">${i + 1}</span>${itemTile(id, "", n)}
      <span class="gp-name"><b>${esc(itemName(id))}</b><small>${stack ? `${n.toLocaleString()} × ${compact(itemPrice(id))}` : `${n.toLocaleString()} obtained`}</small></span>
      <span class="gp-val">${compact(val(id))}</span></button></li>`;
  }).join("");
}

$("clog-card").addEventListener("click", (e) => {
  if (e.target.closest("[data-clog-chart]")) toggleSeries("clog", "Collection log");
  const tab = e.target.closest("[data-gp-tab]");
  if (tab) {
    state.gpTab = tab.dataset.gpTab;
    savePrefs();
    setActive($("gp-tabs"), tab);
    $("clog-card").querySelector(".gp-list").innerHTML = gpTopRows();
    return;
  }
  const it = e.target.closest("[data-item]");
  if (!it) return;
  selectItem(it.dataset.item);
  if (isSel("item", it.dataset.item)) revealItem(it.dataset.item); // like the feed cards
});

// ---------- collection log items + pets (OSRS Data Sync plugin) ----------
// The plugin knows WHICH items are logged; the hiscores know WHEN the count went up and what
// was done in that session. attributeClog() combines the two to match new slots to sessions.

const itemIcon = (id) => icon(`/icons/item/${id}.png`);
const itemName = (id) => titled(state.clog?.names[id] ?? `Item ${id}`);
const initialsOf = (s) => s.replace(/\(.*?\)/g, "").split(/[\s'-]+/).filter(Boolean).map((w) => w[0].toUpperCase()).join("").slice(0, 2);
// Value tiers from GE prices (OSRS Wiki, data\clog\prices.json); pets get their own tier
const VALUE_TIERS = [[10e6, "v4", "#e8b64c"], [1e6, "v3", "#b583ff"], [100e3, "v2", "#5b9dff"]];
const PET_COLOR = "#ff7eb6";
const itemPrice = (id) => state.clog?.prices?.[id] ?? 0;
function valueTier(id) {
  if (state.clog?.petIds.includes(String(id))) return { cls: "vpet", color: PET_COLOR };
  const t = VALUE_TIERS.find(([min]) => itemPrice(id) >= min);
  return t ? { cls: t[1], color: t[2] } : { cls: "", color: null };
}

// count: how many you've received, shown like the game's stack numbers (top-left, yellow)
// badge = false: no count on the picture (Recent updates shows the gain as text; the total is in the tooltip)
function itemTile(id, cls = "", count = 0, badge = true) {
  const n = itemName(id), gp = itemPrice(id);
  const title = (count ? `${n} · ${count.toLocaleString()} obtained` : n) + (gp ? ` · ${compact(gp)} GE` : "");
  if (!/missing|faint/.test(cls)) cls += " " + valueTier(id).cls; // owned items only
  return `<span class="item ${cls}" title="${esc(title)}" data-tile="${esc(id)}" data-initials="${esc(initialsOf(n))}"><img src="${itemIcon(id)}" alt="" loading="lazy" decoding="async">${count && badge ? `<b class="item-n">${compact(count)}</b>` : ""}</span>`;
}

// Log page names as the OSRS Wiki writes them (categories.json "names"); a page missing there gets its key
// in title case: "the_fight_caves" -> "The Fight Caves"
const catName = (k) => titled(state.clog?.catNames?.[k] ?? k.split("_").map((w, i) => (i && ["of", "the", "and"].includes(w) ? w : w[0].toUpperCase() + w.slice(1))).join(" "));
const GROUP_NAMES = { bosses: "Bosses", raids: "Raids", clues: "Clues", minigames: "Minigames", other: "Other" };

// Hiscores boss names that don't match a log page key directly
const BOSS_CATS = {
  callisto: "callisto_and_artio", artio: "callisto_and_artio", venenatis: "venenatis_and_spindel", spindel: "venenatis_and_spindel",
  vetion: "vetion_and_calvarion", calvarion: "vetion_and_calvarion", dagannoth_prime: "dagannoth_kings", dagannoth_rex: "dagannoth_kings",
  dagannoth_supreme: "dagannoth_kings", chambers_of_xeric_challenge_mode: "chambers_of_xeric", theatre_of_blood_hard_mode: "theatre_of_blood",
  tombs_of_amascut_expert_mode: "tombs_of_amascut", the_corrupted_gauntlet: "the_gauntlet", tztok_jad: "the_fight_caves",
  tzkal_zuk: "the_inferno", sol_heredit: "fortis_colosseum", lunar_chests: "moons_of_peril", nightmare: "the_nightmare",
  phosanis_nightmare: "the_nightmare",
};
const slug = (s) => s.toLowerCase().replace(/&/g, "and").replace(/['’]/g, "").replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
function bossCategory(name) {
  const k = slug(name), cats = state.clog.catIndex;
  for (const c of [BOSS_CATS[k], k, "the_" + k, k.replace(/^the_/, "")]) if (c && cats.has(c)) return c;
  return null;
}
// A clue casket can give items from its tier's pages and from the shared clue pages (callers skip pages
// the log doesn't have, e.g. there is no beginner "Rewards (Rare)" page)
const clueCategories = (tier) => [`${tier}_treasure_trails`, `${tier}_treasure_trail_rewards_rare`, "shared_treasure_trail_rewards", "scroll_cases"];
const clueTierOf = (cat) => cat.match(/^(beginner|easy|medium|hard|elite|master)_treasure_trail(s|_rewards_rare)$/)?.[1];

function setClog(raw) {
  if (!raw?.history?.length) { state.clog = null; return; }
  const names = raw.names.items ?? raw.names;
  const latest = raw.history.at(-1);
  const owned = new Map(Object.entries(latest.items).map(([id, [count, date]]) => [id, { count, date }]));
  const catIndex = new Map(); // category -> { group, ids }
  for (const [group, cats] of Object.entries(raw.categories)) {
    if (group === "names") continue;
    for (const [cat, ids] of Object.entries(cats)) catIndex.set(cat, { group, ids: ids.map(String) });
  }
  // The first line read from the plugin after lines from an older source (2026-11-02 01:36 UTC): the plugin reads the
  // whole log, so it lists items and counts the older data never tracked (Prospector set, 232 Demon tears).
  // Those were owned long before, so that line is a new starting point like the first line, not new drops.
  // The saved history is not changed; only how the page reads it.
  const baseline = (li) => li === 0 || (raw.history[li].src === "plugin" && raw.history[li - 1].src !== "plugin");
  // When each item first appeared in the saved history. Items in a starting-point line have no real date.
  const firstSeen = new Map();
  raw.history.forEach((line, li) => {
    for (const [id, [, date]] of Object.entries(line.items)) {
      if (!firstSeen.has(id)) firstSeen.set(id, baseline(li) ? null : new Date(date.replace(" ", "T") + "Z"));
    }
  });
  // Duplicates: an owned item whose count went up between two syncs (no new slot, so the
  // hiscores count doesn't show it). The history keeps the first date, so only the sync window is known.
  const dupes = [];
  for (let li = 1; li < raw.history.length; li++) {
    if (baseline(li)) continue;
    const before = raw.history[li - 1].items;
    for (const [id, [count]] of Object.entries(raw.history[li].items)) {
      const was = before[id]?.[0] ?? 0; // 0 = new item (shown here only if no slot gain claims it)
      if (count > was) dupes.push({ id, from: was, to: count, after: new Date(raw.history[li - 1].t), until: new Date(raw.history[li].t) });
    }
  }
  state.clog = {
    names, owned, catIndex, catNames: raw.categories.names ?? {}, firstSeen, dupes, prices: raw.prices?.prices ?? {}, lines: raw.history, hist: new Map(),
    firstSync: new Date(raw.history[0].t), lastChanged: latest.changed,
    total: latest.total, available: latest.available,
    petIds: catIndex.get("all_pets")?.ids ?? [],
  };
  attributeClog();
}

// Match each session's new slots (from the hiscores) to owned items from the bosses and
// clues done in that session. Confident when no other session competes for the items and the
// numbers add up; otherwise the items are listed as candidates.
function attributeClog() {
  const cl = state.clog, h = state.history;
  if (!cl || !h.length) return;
  const sessions = [];
  for (let i = 1; i < h.length; i++) {
    const prev = h[i - 1], cur = h[i];
    if (!prev.clog || cur.clog <= prev.clog) continue;
    const sources = [];
    for (const [name, total] of Object.entries(cur.bosses)) {
      const g = total - (prev.bosses[name] ?? 0);
      const cat = g > 0 && bossCategory(name);
      if (cat) sources.push({ label: name, gain: g, cats: [cat], boss: name });
    }
    for (const { key } of CLUE_TIERS) {
      const g = (cur.clues[key] ?? 0) - (prev.clues[key] ?? 0);
      if (g > 0) sources.push({ label: `${key[0].toUpperCase() + key.slice(1)} clue${g > 1 ? "s" : ""}`, gain: g, cats: clueCategories(key).filter((c) => cl.catIndex.has(c)), tier: key });
    }
    sessions.push({ time: cur.time, from: prev.time, need: cur.clog - prev.clog, sources, items: [], exact: new Set(), maybe: [], unknown: 0 });
  }

  const assigned = new Map(); // item id -> session
  const give = (id, s, exact) => { assigned.set(id, s); s.items.push(id); if (exact) s.exact.add(id); };
  const candidates = (s) => {
    const ids = new Set();
    for (const src of s.sources) for (const c of src.cats) for (const id of cl.catIndex.get(c).ids) if (cl.owned.has(id) && !assigned.has(id)) ids.add(id);
    return [...ids];
  };

  // 1. Items dated after the first saved sync: the session that refresh falls in
  for (const [id, date] of cl.firstSeen) {
    if (!date) continue;
    const s = sessions.find((x) => date <= x.time && date > x.from) ?? sessions.find((x) => x.time >= date);
    if (s && s.items.length < s.need) give(id, s, true);
  }
  // 1b. The Loot Tracker (plugin): sources whose every recorded kill falls inside one session. A log item they
  //     dropped at least as many times as the log counts was first obtained then, which covers sources the
  //     hiscores don't rank (Doom of Mokhaiotl drops on Oct 31 were otherwise unmatched).
  const lt = Object.values(state.plugin?.kills?.lootTracker ?? {}).flatMap((byName) => Object.values(byName));
  for (const s of sessions) {
    if (s.items.length >= s.need) continue;
    const dropped = new Map();
    for (const r of lt) {
      if (!(r.first > s.from.getTime() && r.last <= s.time.getTime())) continue;
      for (const [id, q] of Object.entries(r.drops ?? {})) dropped.set(id, (dropped.get(id) ?? 0) + q);
    }
    for (const [id, q] of dropped) {
      if (s.items.length >= s.need) break;
      const own = cl.owned.get(id);
      if (own && !assigned.has(id) && !cl.firstSeen.get(id) && own.count <= q) give(id, s, true);
    }
  }
  // 2. Repeat: a session whose unclaimed candidates fit within its remaining slots gets them,
  //    as long as every other session wanting the same items can still fill its own slots
  for (let changed = true; changed;) {
    changed = false;
    const open = sessions.filter((s) => s.items.length < s.need);
    const cands = new Map(open.map((s) => [s, candidates(s)]));
    for (const s of open) {
      const c = cands.get(s), left = s.need - s.items.length;
      if (!c.length || c.length > left) continue;
      const ok = open.every((o) => {
        if (o === s || !cands.get(o).some((id) => c.includes(id))) return true;
        return cands.get(o).filter((id) => !c.includes(id)).length >= o.need - o.items.length;
      });
      if (!ok) continue;
      c.forEach((id) => give(id, s, false));
      changed = true;
      break; // candidate lists changed; recompute
    }
  }
  // 3. What's left: candidates per source (boss / clues), or slots from things the hiscores
  //    don't track. Clue tiers are merged because they share reward categories.
  for (const s of sessions) {
    const left = s.need - s.items.length;
    if (left <= 0) continue;
    const owned = (cats) => [...new Set(cats.flatMap((c) => cl.catIndex.get(c).ids))].filter((id) => cl.owned.has(id) && !assigned.has(id));
    const clueSrc = s.sources.filter((x) => x.tier);
    s.bySource = [
      ...s.sources.filter((x) => x.boss).map((x) => ({ label: x.label, cands: owned(x.cats) })),
      ...(clueSrc.length ? [{ label: clueSrc.map((x) => x.label).join(" + "), clue: true, cands: owned(clueSrc.flatMap((x) => x.cats)) }] : []),
    ].filter((b) => b.cands.length);
    s.maybe = candidates(s);
    s.maybeCount = Math.min(left, s.maybe.length);
    s.unknown = Math.max(0, left - s.maybe.length);
  }
  cl.sessions = sessions;
  cl.assigned = assigned;

  // Put each duplicate on the latest refresh in its sync window where its boss / clue was done,
  // else on the refresh that found it
  for (const d of cl.dupes) {
    if (!d.from && assigned.has(d.id)) { d.at = null; continue; } // already in a "+N slots" entry
    const cats = [...cl.catIndex].filter(([, c]) => c.ids.includes(d.id)).map(([k]) => k);
    let at = null, fallback = null;
    for (let i = 1; i < h.length; i++) {
      const prev = h[i - 1], cur = h[i];
      if (cur.time <= d.after || cur.time > d.until) continue;
      fallback = cur.time;
      const boss = Object.keys(cur.bosses).some((n) => cur.bosses[n] > (prev.bosses[n] ?? 0) && cats.includes(bossCategory(n)));
      const clue = CLUE_TIERS.some(({ key }) => (cur.clues[key] ?? 0) > (prev.clues[key] ?? 0) && clueCategories(key).some((c) => cats.includes(c)));
      if (boss || clue) at = cur.time;
    }
    d.at = at ?? fallback;
    d.matched = !!at;
  }
}

// Item chips for a group of sessions (a day, a feed entry)
function clogItemsHtml(sessions, { compact = false } = {}) {
  if (!state.clog || !sessions.length) return "";
  const items = sessions.flatMap((s) => s.items);
  const maybeCount = sessions.reduce((t, s) => t + (s.maybeCount || 0), 0);
  const unknown = sessions.reduce((t, s) => t + s.unknown, 0);
  // Candidates grouped by where they'd come from, merged across the sessions shown
  const groups = new Map();
  for (const s of sessions) for (const b of s.bySource ?? []) {
    const g = groups.get(b.label) ?? { label: b.label, clue: b.clue, ids: new Set() };
    b.cands.forEach((id) => g.ids.add(id));
    groups.set(b.label, g);
  }
  const cap = compact ? 6 : 10;
  let html = "";
  if (items.length) {
    html += `<div class="clog-items">${items.map((id) => {
      const exact = sessions.some((s) => s.exact.has(id));
      return `<span class="clog-item ${exact ? "exact" : ""} ${valueTier(id).cls} ${isSel("item", id) ? "sel" : ""}" data-item="${esc(id)}" title="${esc(itemName(id))}${exact ? " · logged then" : " · best match"}">${itemTile(id, "", state.clog.owned.get(id)?.count ?? 0)}<span>${esc(itemName(id))}</span></span>`;
    }).join("")}</div>`;
  }
  if (maybeCount) {
    html += `<div class="clog-maybe-head">${items.length ? `${maybeCount} more, likely from` : `Likely from`}</div>`;
    for (const g of groups.values()) {
      const ids = [...g.ids];
      // Small pools (a boss's few drops) are worth showing; big clue pools get summarised
      const few = ids.length <= cap;
      html += `<div class="clog-maybe">
        <span class="clog-src">${esc(g.label)}</span>
        ${few ? ids.map((id) => itemTile(id, "faint")).join("")
              : `${ids.slice(0, 4).map((id) => itemTile(id, "faint")).join("")}<span class="muted small">${ids.length} possible rewards</span>`}
      </div>`;
    }
  }
  return html;
}
// When each copy of an item was obtained, as far as the data knows: { base, steps: [{ time, n, how }] }.
// base = copies with no known date (in the first saved sync, which stamps everything with the sync
// date). how: "exact" (dated in the history / exact slot match), "likely" (best slot match), "sync" (count
// went up between two syncs: placed like the feed does).
function itemHistory(id) {
  const cl = state.clog;
  if (cl.hist.has(id)) return cl.hist.get(id);
  let base = 0, prev = 0;
  const steps = [];
  cl.lines.forEach((line, li) => {
    const count = line.items[id]?.[0] ?? 0;
    if (count > prev) {
      const n = count - prev;
      if (prev) {
        const d = cl.dupes.find((x) => x.id === id && +x.until === +new Date(line.t));
        steps.push({ time: d?.at ?? new Date(line.t), n, how: "sync" });
      } else if (li > 0) {
        steps.push({ time: cl.firstSeen.get(id) ?? new Date(line.t), n, how: "exact" });
      } else {
        const s = cl.assigned.get(id);
        if (s) steps.push({ time: s.time, n: 1, how: s.exact.has(id) ? "exact" : "likely" });
        base += s ? n - 1 : n;
      }
    }
    prev = Math.max(prev, count);
  });
  steps.sort((a, b) => a.time - b.time);
  const out = { base, steps };
  cl.hist.set(id, out);
  return out;
}
const itemCountAt = (id, time) => {
  const { base, steps } = itemHistory(id);
  return steps.reduce((t, s) => t + (s.time <= time ? s.n : 0), base);
};

// Click an item (Recent updates, feed) or a boss / collection log card in the feed: show it on the
// chart (+ the item in the detail card); click again to remove it. The page doesn't scroll.
const showSeries = (kind, name) => toggleSeries(kind, name);
const selectItem = (id) => showSeries("item", id);

function renderItemDetail(c, id) {
  const cl = state.clog, { base, steps } = itemHistory(id);
  const vt = valueTier(id), gp = itemPrice(id);
  const count = cl.owned.get(id)?.count ?? 0;
  const inView = steps.filter((s) => s.time > c.base.time).reduce((t, s) => t + s.n, 0);
  const cats = [...cl.catIndex].filter(([, x]) => x.ids.includes(id)).map(([k]) => catName(k));
  const when = (d) => d.toLocaleString(undefined, { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
  const HOW = { exact: "", likely: "likely · matched to new slots that session", sync: "found on this update" };
  const first = base ? null : steps[0];
  const rows = [
    ["Obtained", count.toLocaleString()],
    // Prices are only kept for items you've obtained, so a missing one isn't "Untradeable"
    ["GE Value", gp ? `${compact(gp)}${count > 1 ? ` · ${compact(gp * count)} total` : ""}` : count ? "Untradeable" : "–"],
    ["This Period", inView ? "+" + inView.toLocaleString() : "–", inView > 0],
    ["First Obtained", first ? first.time.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }) + (first.how === "likely" ? " (likely)" : "") : "Before Tracking"],
  ];
  const list = [...steps].reverse().map((s) => `<div class="item-hist-row">
      <div><b>${when(s.time)}</b>${HOW[s.how] ? `<span>${HOW[s.how]}</span>` : ""}</div><em>+${s.n.toLocaleString()}</em></div>`).join("")
    + (base ? `<div class="item-hist-row muted"><div><b>Before ${cl.firstSync.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}</b><span>logged before tracking began · dates unknown</span></div><em>${base.toLocaleString()}</em></div>` : "");

  $("detail").innerHTML = `
    <div class="detail-head">
      <div class="detail-icon"><img src="${itemIcon(id)}" alt=""></div>
      <div>
        <h3 class="item-title ${vt.cls}">${esc(itemName(id))}</h3>
        <div class="detail-level">${cats.length ? esc(cats.join(" · ")) : "Collection Log"}</div>
      </div>
      <button class="pill-toggle" id="item-close" data-id="${esc(id)}" style="margin-left:auto;padding:5px 10px;font-size:13px;color:var(--text-2)">Close</button>
    </div>
    <div class="stat-list">${rows.map(([k, v, g]) => `<div class="stat-row"><span>${k}</span><b class="${g ? "pos" : ""}">${v}</b></div>`).join("")}</div>
    <div class="top-gains"><h4>History</h4><div class="item-hist">${list || `<p class="muted small" style="margin:0">No history yet.</p>`}</div></div>`;
}

// Chips for duplicates / new items: "Hespori seed +2". No number on the picture (the total there read as
// "gained 63"); the total is in the tooltip ("Hespori seed · 63 obtained")
function clogExtrasHtml(list) {
  if (!list.length) return "";
  return `<div class="clog-items">${list.map((d) => `<span class="clog-item exact ${valueTier(d.id).cls} ${isSel("item", d.id) ? "sel" : ""}" data-item="${esc(d.id)}" title="${esc(itemName(d.id))} · ${d.from ? `${d.from} → ${d.to}` : `new, ${d.to}`} obtained">${itemTile(d.id, "", d.to, false)}<span>${esc(itemName(d.id))} <em>${d.from ? `+${d.to - d.from}` : "new"}</em></span></span>`).join("")}</div>`;
}
const clogSessionsBetween = (from, to) => (state.clog?.sessions ?? []).filter((s) => s.time >= from && s.time < to);

// Kill / completion counts per collection log category, from the latest hiscores snapshot.
// Variants are combined (Chambers of Xeric + Challenge Mode, the three Dagannoth Kings, ...).
function categoryCounts(snap) {
  const out = new Map();
  if (!snap || !state.clog) return out;
  const add = (cat, label, n, unit) => {
    if (!cat || !n) return;
    const e = out.get(cat) ?? { total: 0, parts: [], unit };
    e.total += n;
    e.parts.push([label, n]);
    out.set(cat, e);
  };
  const unitFor = (cat) => {
    const group = state.clog.catIndex.get(cat)?.group;
    if (group === "raids" || ["fortis_colosseum", "the_fight_caves", "the_inferno", "the_gauntlet"].includes(cat)) return "completions";
    if (cat === "barrows_chests" || cat === "moons_of_peril") return "chests";
    return "kills";
  };
  for (const [name, n] of Object.entries(snap.bosses)) {
    const cat = bossCategory(name);
    add(cat, name, n, unitFor(cat));
  }
  for (const { key } of CLUE_TIERS) for (const c of [`${key}_treasure_trails`, `${key}_treasure_trail_rewards_rare`]) if (state.clog.catIndex.has(c)) add(c, key, snap.clues[key] ?? 0, "completed");
  add("guardians_of_the_rift", "Rifts Closed", snap.rifts ?? 0, "rifts closed");
  return out;
}

function renderClogItems() {
  const box = $("clog-items-card"), pets = $("pets-card");
  const cl = state.clog;
  box.hidden = pets.hidden = !cl;
  if (!cl) return;
  const synced = (d) => d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });

  // Items browser: one tab per group, a row per category, expandable to every item
  const group = state.clogGroup ?? "bosses";
  const groups = [...new Set([...cl.catIndex.values()].map((c) => c.group))];
  const counts = categoryCounts(state.history.at(-1));
  // Category icon: the official boss icon, the clue tier's scroll, or else the page's first item
  const bossFor = new Map();
  for (const name of Object.keys(state.history.at(-1)?.bosses ?? {})) {
    const cat = bossCategory(name);
    if (cat && !bossFor.has(cat)) bossFor.set(cat, name);
  }
  const catIcon = (cat, c) => {
    const tier = clueTierOf(cat);
    if (tier) return `<span class="cat-ic"><img src="${gameIcon("cluescrolls" + tier)}" alt="" loading="lazy"></span>`;
    if (bossFor.has(cat)) return `<span class="cat-ic" ${bossIconHtml(bossFor.get(cat))}</span>`;
    return `<span class="cat-ic" data-initials="${esc(initialsOf(catName(cat)))}"><img src="${itemIcon(c.ids[0])}" alt="" loading="lazy"></span>`;
  };
  const rows = [...cl.catIndex.entries()].filter(([, c]) => c.group === group).map(([cat, c]) => {
    const have = c.ids.filter((id) => cl.owned.has(id)).length;
    const open = state.clogOpen === cat;
    const kc = counts.get(cat);
    const kcText = kc ? `${kc.total.toLocaleString()} ${kc.unit}` : "";
    const parts = kc && kc.parts.length > 1 ? kc.parts.map(([l, n]) => `${esc(l)} ${n.toLocaleString()}`).join(" · ") : "";
    return `<div class="cat ${have ? "" : "none"} ${have === c.ids.length ? "done" : ""} ${open ? "open" : ""}">
      <button type="button" class="cat-row" data-cat="${cat}" aria-expanded="${open}" ${parts ? `title="${parts}"` : ""}>
        ${catIcon(cat, c)}
        <span class="cat-name">${esc(catName(cat))}<small class="cat-kc">${kcText}</small></span>
        <span class="bar-track"><span class="bar-fill ${have === c.ids.length ? "" : "green"}" style="display:block;width:${(have / c.ids.length * 100).toFixed(1)}%"></span></span>
        <span class="cat-count"><b>${have}</b>/${c.ids.length}</span>
      </button>
      ${open && parts ? `<div class="cat-parts">${parts}</div>` : ""}
      ${open ? `<div class="cat-items">${c.ids.map((id) => cl.owned.has(id) ? itemTile(id, "", cl.owned.get(id).count) : itemTile(id, "missing")).join("")}</div>` : ""}
    </div>`;
  }).join("");
  const pct = (cl.total / cl.available * 100).toFixed(1);
  const listScroll = box.querySelector(".cat-list")?.scrollTop ?? 0; // keep the list where it was
  // Card icons: your most valuable logged item, and your first pet (icons already saved locally)
  const best = [...cl.owned.keys()].reduce((a, id) => ((itemPrice(id) ?? 0) > (itemPrice(a) ?? 0) ? id : a), [...cl.owned.keys()][0]);
  const pet = cl.petIds.find((id) => cl.owned.has(id));
  const headIcon = (id, title) => `<span class="clog-icon" title="${esc(title)}" data-initials="${esc(initialsOf(itemName(id ?? "")))}">${id
    ? `<img class="clog-icon-item" src="${itemIcon(id)}" alt="">` : `<img src="${wikiIcon("Collection_log.png")}" alt="">`}</span>`;
  const navImg = document.querySelector('#sec-nav [data-target="sec-items"] svg, #sec-nav [data-target="sec-items"] img');
  if (navImg && best) navImg.outerHTML = `<img src="${itemIcon(best)}" alt="">`;
  box.innerHTML = `
    <div class="card-head">
      <div class="clog-head">${headIcon(best, best ? `Most Valuable: ${itemName(best)}` : "")}
      <div><h3>Collection Log Items</h3><p class="muted small">${cl.total.toLocaleString()} / ${cl.available.toLocaleString()} (${pct}%) · from OSRS Data Sync (RuneLite) · last change ${synced(new Date(cl.lastChanged.replace(" ", "T") + "Z"))}</p></div></div>
      <div class="pill-toggle" id="clog-groups">${groups.map((g) => `<button data-group="${g}" class="${g === group ? "active" : ""}">${GROUP_NAMES[g] ?? catName(g)}</button>`).join("")}</div>
    </div>
    <div class="cat-list">${rows}</div>`;
  box.querySelector(".cat-list").scrollTop = listScroll;

  // Pets: owned first (with when they were logged, if known), then the rest faded
  const owned = cl.petIds.filter((id) => cl.owned.has(id));
  const locked = cl.petIds.filter((id) => !cl.owned.has(id));
  const when = (id) => {
    const s = cl.assigned.get(id);
    if (s) return `${s.exact.has(id) ? "Logged" : "Likely Logged"} ${s.time.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}`;
    const d = cl.firstSeen.get(id);
    return d ? `Logged ${d.toLocaleDateString()}` : `Logged before ${synced(cl.firstSync)}`;
  };
  pets.innerHTML = `
    <div class="card-head"><div class="clog-head">${headIcon(pet, pet ? itemName(pet) : "")}
      <div><h3>Pets</h3><p class="muted small">${owned.length} of ${cl.petIds.length} pets · from your collection log</p></div></div></div>
    <div class="pets-owned">${owned.length ? owned.map((id) => `<div class="pet">${itemTile(id)}<div><b>${esc(itemName(id))}</b><span>${when(id)}</span></div></div>`).join("") : `<p class="muted small">No pets yet.</p>`}</div>
    <h4 class="pets-h">Still to Get</h4>
    <div class="pets-locked">${locked.map((id) => itemTile(id, "missing")).join("")}</div>`;
}

$("clog-items-card").addEventListener("click", (e) => {
  const g = e.target.closest("[data-group]");
  if (g) {
    state.clogGroup = g.dataset.group;
    savePrefs();
    state.clogOpen = null;
    renderClogItems();
    $("clog-items-card").querySelector(".cat-list").scrollTop = 0; // new tab starts at the top
    return;
  }
  const row = e.target.closest("[data-cat]");
  if (row) { state.clogOpen = state.clogOpen === row.dataset.cat ? null : row.dataset.cat; renderClogItems(); }
});

// ---------- quests + achievement diaries (OSRS Data Sync plugin) ----------

const QUEST_STATES = { 2: "done", 1: "started", 0: "todo" };
const DIARY_TIERS = ["Easy", "Medium", "Hard", "Elite"];

function renderQuests() {
  const box = $("qd-card");
  const w = state.progress;
  box.hidden = !w?.quests;
  if (!w?.quests) return;

  // Quests and miniquests are listed separately (miniquest names: OSRS Wiki category, saved locally)
  const mini = new Set(state.miniquests ?? []);
  const all = Object.entries(w.quests).sort((a, b) => a[0].replace(/^(A|An|The) /, "").localeCompare(b[0].replace(/^(A|An|The) /, "")));
  const kinds = { quests: all.filter(([n]) => !mini.has(n)), mini: all.filter(([n]) => mini.has(n)) };
  const kind = kinds[state.questKind] ? state.questKind : "quests";
  const quests = kinds[kind];
  const doneOf = (list) => list.filter(([, s]) => s === 2).length;
  const noun = kind === "mini" ? "miniquest" : "quest";
  const by = { done: [], started: [], todo: [] };
  for (const [name, s] of quests) by[QUEST_STATES[s] ?? "todo"].push(name);
  const filter = state.questFilter ?? "open";
  const shown = filter === "done" ? by.done : filter === "all" ? quests.map(([n]) => n) : [...by.started, ...by.todo];
  const pct = (by.done.length / quests.length * 100).toFixed(1);
  const questRow = (name) => {
    const s = QUEST_STATES[w.quests[name]] ?? "todo";
    const label = { done: "Completed", started: "In Progress", todo: "Not Started" }[s];
    const open = state.questPick === name;
    return `<li class="q ${s} ${open ? "open" : ""}" data-quest="${esc(name)}" role="button" tabindex="0" aria-expanded="${open}">
      <span class="q-dot" title="${label}"></span><span class="q-name">${esc(name)}</span><span class="q-state">${label}</span></li>
      ${open ? `<li class="q-req">${questDetail(name, w)}</li>` : ""}`;
  };

  // Diaries: region x tier grid
  const regions = Object.keys(w.diaries).sort();
  // A tier the plugin reports as unfinished has no task count (done = null): it only knows whole tiers
  let tiersDone = 0, tiersAll = 0, tasksDone = 0, tasksAll = 0, unknown = 0;
  const cells = regions.map((r) => {
    const row = DIARY_TIERS.map((t) => {
      const [d, n] = w.diaries[r][t] ?? [0, 0];
      if (!n) return `<td></td>`;
      tiersAll++; tasksAll += n; tasksDone += d ?? 0; if (d == null) unknown++;
      const key = `${r}|${t}`, sel = state.diaryPick === key ? "sel" : "";
      if (d == null) return `<td><button type="button" class="dt none ${sel}" data-diary="${esc(key)}" title="${esc(r)} ${t}: not finished (${n} tasks)"><b>–</b>/${n}</button></td>`;
      if (d >= n) { tiersDone++; return `<td><button type="button" class="dt done ${sel}" data-diary="${esc(key)}" title="${esc(r)} ${t}: complete">✓</button></td>`; }
      return `<td><button type="button" class="dt ${d ? "part" : "none"} ${sel}" data-diary="${esc(key)}" title="${esc(r)} ${t}: ${d} of ${n} tasks"><b>${d}</b>/${n}<i style="width:${(d / n * 100).toFixed(0)}%"></i></button></td>`;
    }).join("");
    const all = DIARY_TIERS.every((t) => { const [d, n] = w.diaries[r][t] ?? [0, 0]; return n && d != null && d >= n; });
    return `<tr class="${all ? "all" : ""}"><th>${esc(r)}</th>${row}</tr>`;
  }).join("");

  const synced = new Date(w.timestamp).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  const listScroll = box.querySelector(".q-list")?.scrollTop ?? 0; // keep the quest list where it was
  box.innerHTML = `
    <div class="card-head">
      <div class="clog-head"><span class="clog-icon"><img src="${wikiIcon("Quest_point_icon.png")}" alt=""></span>
        <div><h3>Quests &amp; Achievement Diaries</h3><p class="muted small">From OSRS Data Sync (RuneLite) · synced ${synced}</p></div></div>
    </div>
    <div class="qd-grid">
      <div class="qd-quests">
        <div class="qd-kind" role="tablist">
          <button data-qk="quests" class="${kind === "quests" ? "active" : ""}" role="tab" aria-selected="${kind === "quests"}">Quests <span>${doneOf(kinds.quests)}/${kinds.quests.length}</span></button>
          <button data-qk="mini" class="${kind === "mini" ? "active" : ""}" role="tab" aria-selected="${kind === "mini"}">Miniquests <span>${doneOf(kinds.mini)}/${kinds.mini.length}</span></button>
        </div>
        <div class="qd-sum">
          <div><b>${by.done.length}</b><span>/ ${quests.length} completed (${pct}%)</span></div>
          <div class="bar-track"><div class="bar-fill" style="width:${pct}%"></div></div>
          <div class="qd-legend"><span class="q done"><span class="q-dot"></span>${by.done.length} done</span><span class="q started"><span class="q-dot"></span>${by.started.length} in progress</span><span class="q todo"><span class="q-dot"></span>${by.todo.length} not started</span></div>
        </div>
        <div class="pill-toggle" id="quest-filter">
          <button data-qf="open" class="${filter === "open" ? "active" : ""}">To Do (${by.started.length + by.todo.length})</button>
          <button data-qf="done" class="${filter === "done" ? "active" : ""}">Completed (${by.done.length})</button>
          <button data-qf="all" class="${filter === "all" ? "active" : ""}">All</button>
        </div>
        <ul class="q-list">${shown.length ? shown.map(questRow).join("") : `<li class="muted small">${filter === "done" ? `No ${noun}s completed yet.` : `Every ${noun} is done!`}</li>`}</ul>
      </div>
      <div class="qd-diaries">
        <div class="qd-sum">
          <div><img src="${wikiIcon("Achievement_Diaries_icon.png")}" alt="" class="qd-ic"><b>${tiersDone}</b><span>/ ${tiersAll} diaries complete${unknown ? "" : ` · ${tasksDone} / ${tasksAll} tasks`}</span></div>
        </div>
        <div class="diary-wrap"><table class="diary">
          <thead><tr><th></th>${DIARY_TIERS.map((t) => `<th>${t}</th>`).join("")}</tr></thead>
          <tbody>${cells}</tbody>
        </table></div>
        <div class="dd" id="diary-detail">${diaryDetail(w)}</div>
      </div>
    </div>`;
  box.querySelector(".q-list").scrollTop = listScroll;
}

// Quest names compared without case or punctuation: the wiki's "The Writing's on the Wall" is RuneLite's
// "The Writings on the Wall"
const questKey = (s) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
const questIndex = { src: null, reqs: new Map(), states: null, states2: new Map() };
function questReqsOf(name) {
  if (questIndex.src !== state.questReqs) {
    questIndex.src = state.questReqs;
    questIndex.reqs = new Map(Object.entries(state.questReqs ?? {}).map(([k, v]) => [questKey(k), v]));
  }
  return questIndex.reqs.get(questKey(name));
}
function questStateOf(name, w) {
  if (name in w.quests) return w.quests[name];
  if (questIndex.states !== w.quests) {
    questIndex.states = w.quests;
    questIndex.states2 = new Map(Object.entries(w.quests).map(([k, v]) => [questKey(k), v]));
  }
  return questIndex.states2.get(questKey(name));
}

// Requirements of the clicked quest (OSRS Wiki), checked against your levels and finished quests
function questDetail(name, w) {
  const r = questReqsOf(name);
  if (!r) return `<p class="muted small">Requirements aren't saved yet.</p>`;
  const list = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
  const skills = state.history.at(-1)?.skills ?? {};
  const have = (s) => (s === "Combat" ? combatLevel(skills) : skills[s]?.level ?? 1);
  const chip = (s, lvl, boost) => {
    const ok = have(s) >= lvl;
    const tip = `You have ${have(s)} ${s}${boost == null ? "" : boost ? " · boostable" : " · not boostable"}`;
    return `<span class="dd-chip ${ok ? "ok" : "no"}" title="${esc(tip)}"><img src="${s === "Combat" ? wikiIcon("Combat_icon.png") : skillIcon(s)}" alt="">${lvl} ${esc(s)}</span>`;
  };
  const chips = [
    ...list(r.skills).map(([s, lvl, boost]) => chip(s, lvl, boost)),
    r.combat ? chip("Combat", r.combat, null) : "",
    r.qp ? `<span class="dd-chip"><img src="${wikiIcon("Quest_point_icon.png")}" alt="">${r.qp} Quest Points</span>` : "",
  ].join("");
  const quests = list(r.quests).map(([q, depth]) => {
    const st = questStateOf(q, w);
    const cls = st === 2 ? "ok" : st === 1 ? "mid" : "no";
    const tip = st === 2 ? "Completed" : st === 1 ? "In Progress" : "Not Started";
    return `<li class="qr-q ${cls}" style="--depth:${depth}" title="${tip}"><span class="qr-mark">${st === 2 ? "✓" : ""}</span>${esc(q)}</li>`;
  }).join("");
  const extra = list(r.extra), items = list(r.items);
  if (!chips && !quests && !extra.length && !items.length) return `<p class="muted small">No Requirements</p>`;
  return `
    ${chips ? `<div class="dd-sec"><span class="dd-label">Skills</span><div class="dd-chips">${chips}</div></div>` : ""}
    ${quests ? `<div class="dd-sec"><span class="dd-label">Quests</span><ul class="qr-quests">${quests}</ul></div>` : ""}
    ${extra.length ? `<div class="dd-sec"><span class="dd-label">Also</span><ul class="dd-extra">${extra.map((x) => `<li>${esc(x)}</li>`).join("")}</ul></div>` : ""}
    ${items.length ? `<div class="dd-sec"><span class="dd-label">Items</span><ul class="dd-extra">${items.map((x) => `<li>${esc(x)}</li>`).join("")}</ul></div>` : ""}`;
}

// Tasks and requirements for the clicked diary tier, checked against your levels and quests
function diaryDetail(w) {
  if (!state.diaryPick) return "";
  const [r, t] = state.diaryPick.split("|");
  const raw = state.diaryInfo?.[r]?.[t];
  // The saved file can hold a single entry as a plain value instead of a one-item list
  const list = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
  // An empty wiki cell is saved as {}: show text entries only
  const texts = (v) => list(v).filter((x) => typeof x === "string" && x.trim());
  const info = raw && { skills: raw.skills ?? {}, quests: texts(raw.quests), extra: texts(raw.extra), tasks: list(raw.tasks).map((x) => ({ ...x, req: texts(x.req) })) };
  const [d, n, flags = ""] = w.diaries[r]?.[t] ?? [0, 0, ""];
  const head = `<div class="dd-head"><h4>${esc(r)} · ${t}</h4><span class="${d != null && d >= n ? "pos" : "muted"}">${d == null ? "Not Finished" : d >= n ? "Complete" : `${d} / ${n} tasks`}</span>
    <button type="button" class="dd-close" data-diary-close title="Close">✕</button></div>`;
  if (!info) return head + `<p class="muted small">Task details aren't saved yet.</p>`;

  const skills = state.history.at(-1)?.skills ?? {};
  const have = (s) => (s === "Combat" ? combatLevel(skills) : skills[s]?.level ?? 1);
  const skillChips = Object.entries(info.skills).map(([s, lvl]) => {
    if (s === "Quest") return `<span class="dd-chip"><img src="${wikiIcon("Quest_point_icon.png")}" alt="">${lvl} quest points</span>`;
    const ok = have(s) >= lvl;
    return `<span class="dd-chip ${ok ? "ok" : "no"}" title="You have ${have(s)} ${s}"><img src="${s === "Combat" ? wikiIcon("Combat_icon.png") : skillIcon(s)}" alt="">${lvl} ${esc(s)}</span>`;
  }).join("");
  const questChips = info.quests.map((q) => {
    const st = w.quests[q];
    const cls = st === 2 ? "ok" : st === 1 ? "mid" : st === 0 ? "no" : "";
    return `<span class="dd-chip ${cls}" title="${st === 2 ? "Completed" : st === 1 ? "In Progress" : st === 0 ? "Not Started" : ""}">${st === 2 ? "✓ " : ""}${esc(q)}</span>`;
  }).join("");
  const tasks = info.tasks.map((x, i) => {
    const done = flags[i] === "1";
    return `<li class="${done ? "done" : ""}">
      <span class="dd-check">${done ? "✓" : ""}</span>
      <div><div class="dd-task">${esc(x.task)}</div>
        ${x.req.length ? `<div class="dd-req">${x.req.map(esc).join(" · ")}</div>` : ""}
        ${x.note ? `<div class="dd-note">${esc(x.note)}</div>` : ""}</div>
    </li>`;
  }).join("");
  return head + `
    ${skillChips ? `<div class="dd-sec"><span class="dd-label">Skills</span><div class="dd-chips">${skillChips}</div></div>` : ""}
    ${questChips ? `<div class="dd-sec"><span class="dd-label">Quests</span><div class="dd-chips">${questChips}</div></div>` : ""}
    ${info.extra.length ? `<div class="dd-sec"><span class="dd-label">Also</span><ul class="dd-extra">${info.extra.map((x) => `<li>${esc(x)}</li>`).join("")}</ul></div>` : ""}
    <div class="dd-sec"><span class="dd-label">Tasks</span><div>${d == null ? `<p class="muted small dd-unknown">Which of these are done isn't known: OSRS Data Sync reports whole tiers only.</p>` : ""}<ol class="dd-tasks">${tasks}</ol></div></div>`;
}

$("qd-card").addEventListener("click", (e) => {
  const k = e.target.closest("[data-qk]");
  if (k) {
    state.questKind = k.dataset.qk;
    savePrefs();
    renderQuests();
    $("qd-card").querySelector(".q-list").scrollTop = 0;
    return;
  }
  const b = e.target.closest("[data-qf]");
  if (b) {
    state.questFilter = b.dataset.qf;
    savePrefs();
    return renderQuests();
  }
  const q = e.target.closest("[data-quest]");
  if (q) {
    state.questPick = state.questPick === q.dataset.quest ? null : q.dataset.quest;
    return renderQuests();
  }
  const cell = e.target.closest("[data-diary]");
  if (cell || e.target.closest("[data-diary-close]")) {
    state.diaryPick = cell && state.diaryPick !== cell.dataset.diary ? cell.dataset.diary : null;
    renderQuests();
  }
});

$("qd-card").addEventListener("keydown", (e) => {
  if ((e.key === "Enter" || e.key === " ") && e.target.matches("[data-quest]")) {
    e.preventDefault();
    e.target.click();
  }
});

// ---------- combat achievements (done = OSRS Data Sync plugin, task list = OSRS Wiki, saved locally) ----------

const CA_TIERS = ["Easy", "Medium", "Hard", "Elite", "Master", "Grandmaster"];
const CA_POINTS = { Easy: 1, Medium: 2, Hard: 3, Elite: 4, Master: 5, Grandmaster: 6 };
const caIcon = (tier) => wikiIcon(`Combat_Achievements_-_${tier.toLowerCase()}_tier_icon.png`);
const caSortName = (s) => s.replace(/^The /, "");
// CA monsters the hiscores list under another name (same kill count)
const CA_BOSS_ALIAS = { "Barrows": "Barrows Chests", "Crystalline Hunllef": "The Gauntlet", "Corrupted Hunllef": "The Corrupted Gauntlet",
  "Fortis Colosseum": "Sol Heredit", "Moons of Peril": "Lunar Chests" };
// Same boss icon only (entry modes have no hiscores kill count)
const CA_ICON_ALIAS = { "Theatre of Blood: Entry Mode": "Theatre of Blood", "Tombs of Amascut: Entry Mode": "Tombs of Amascut" };
// Every other non-boss monster: icons\ca\<slug>.png, made once by tools\fetch-ca-icons.ps1
const caMonIcon = (name) => icon(`/icons/ca/${name.toLowerCase().replace(/[^a-z0-9]/g, "")}.png`);
// Same as the .t-<tier> colours in styles.css (in-game sword metals)
const CA_COLORS = { Easy: "#c99a62", Medium: "#b9bcc4", Hard: "#8fb3d9", Elite: "#9b9cf5", Master: "#5fd38a", Grandmaster: "#4cc9ef" };

// Refresh time (ms) -> tasks reported as finished since its previous change. The first saved
// list is the baseline (everything done before tracking started), so it adds nothing to the feed.
function caFinishedByRefresh() {
  const out = new Map(), hist = state.caHistory ?? [], h = state.history;
  if (!state.caInfo?.tasks || hist.length < 2 || !h.length) return out;
  const d = caData(), byId = new Map(d.tasks.map((t) => [t.id, t]));
  const bossOf = new Map(d.mons.map((m) => [m.name, m.boss]));
  for (let i = 1; i < hist.length; i++) {
    const was = new Set(hist[i - 1].ca);
    // The timestamp is the plugin sync; the first refresh after it is the one that read it
    const at = new Date(hist[i].t), snap = h.find((s) => s.time >= at) ?? h.at(-1);
    for (const id of hist[i].ca) {
      const t = byId.get(id);
      if (was.has(id) || !t) continue;
      if (!out.has(+snap.time)) out.set(+snap.time, []);
      out.get(+snap.time).push({ ...t, boss: bossOf.get(t.monster) });
    }
  }
  return out;
}

// Everything the card needs, rebuilt only when the progress data or the task list changes
function caData() {
  const info = state.caInfo, w = state.progress;
  if (state.caMemo?.info === info && state.caMemo?.w === w) return state.caMemo;
  const done = new Set(w?.ca ?? []);
  const tasks = info.tasks.map((t) => ({ ...t, done: done.has(t.id), pts: CA_POINTS[t.tier] ?? 0 }));
  const tiers = Object.fromEntries(CA_TIERS.map((t) => [t, { done: 0, all: 0 }]));
  const mons = new Map();
  let points = 0, total = 0;
  for (const t of tasks) {
    total += t.pts;
    if (t.done) points += t.pts;
    const tier = tiers[t.tier];
    if (tier) { tier.all++; if (t.done) tier.done++; }
    if (!mons.has(t.monster)) mons.set(t.monster, { name: t.monster, done: 0, all: 0 });
    const m = mons.get(t.monster);
    m.all++; if (t.done) m.done++;
  }
  // Points needed per reward tier (wiki); Grandmaster needs every task
  const need = { ...info.points, Grandmaster: total };
  const rank = CA_TIERS.filter((t) => points >= need[t]).pop() ?? null;
  const next = CA_TIERS.find((t) => points < need[t]) ?? null;
  // Hiscores boss names, for the boss icon and kill count ("The Hueycoatl" -> "Hueycoatl")
  const key = (s) => caSortName(s).toLowerCase().replace(/[^a-z0-9]/g, "");
  const bosses = new Map(Object.keys(state.history.at(-1)?.bosses ?? {}).map((n) => [key(n), n]));
  for (const m of mons.values()) {
    m.boss = bosses.get(key(m.name)) ?? bosses.get(key(CA_BOSS_ALIAS[m.name] ?? "")) ?? null;
    m.iconBoss = m.boss ?? CA_ICON_ALIAS[m.name] ?? null;
  }
  const monList = [...mons.values()].sort((a, b) => caSortName(a.name).localeCompare(caSortName(b.name)));
  tasks.sort((a, b) => CA_TIERS.indexOf(a.tier) - CA_TIERS.indexOf(b.tier) || a.name.localeCompare(b.name));
  return (state.caMemo = { info, w, tasks, tiers, mons: monList, points, total, need, rank, next, synced: !!w?.ca });
}

function renderCa() {
  const box = $("ca-card");
  box.hidden = !state.caInfo?.tasks;
  if (box.hidden) return;
  const d = caData();
  const tier = CA_TIERS.includes(state.caTier) ? state.caTier : null;
  const status = state.caStatus ?? "open";
  const inTier = d.tasks.filter((t) => !tier || t.tier === tier);
  const doneN = inTier.filter((t) => t.done).length;

  const toNext = d.next ? d.need[d.next] - d.points : 0;
  const prevNeed = d.rank ? d.need[d.rank] : 0;
  const pct = d.next ? ((d.points - prevNeed) / (d.need[d.next] - prevNeed) * 100) : 100;
  const doneAll = d.tasks.filter((t) => t.done).length;
  const tiles = CA_TIERS.map((t) => {
    const s = d.tiers[t], reached = d.points >= d.need[t];
    return `<button type="button" class="ca-tier-tile t-${t.toLowerCase()} ${tier === t ? "active" : ""} ${reached ? "reached" : ""}" data-ca-tier="${t}"
        title="${t}: ${s.done} of ${s.all} tasks · rank unlocks at ${fmt(d.need[t])} points${reached ? " (unlocked)" : ""}">
      <img src="${caIcon(t)}" alt=""><span class="ca-tt-name">${t}</span>
      <span class="ca-tt-n"><b>${s.done}</b>/${s.all}</span>
      <span class="bar-track"><span class="bar-fill" style="width:${(s.done / s.all * 100).toFixed(1)}%"></span></span>
      <span class="ca-tt-need">${reached ? "✓ " : ""}${fmt(d.need[t])} pts</span>
    </button>`;
  }).join("");

  const synced = state.progress?.timestamp ? new Date(state.progress.timestamp).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "";
  const monScroll = box.querySelector(".ca-mons")?.scrollTop ?? 0;
  const listScroll = box.querySelector(".ca-list")?.scrollTop ?? 0;
  const rowsShown = box.querySelectorAll(".ca-row").length; // redraw at least as many, so the scroll spot still exists
  box.innerHTML = `
    <div class="card-head">
      <div class="clog-head"><span class="clog-icon"><img src="${caIcon("Grandmaster")}" alt=""></span>
        <div><h3>Combat Achievements</h3><p class="muted small">${d.synced ? `From OSRS Data Sync (RuneLite) · synced ${synced}` : "Task list from the OSRS Wiki"}</p></div></div>
    </div>
    ${d.synced ? "" : `<p class="ca-note">Your finished tasks load on the next Update (OSRS Data Sync).</p>`}
    <div class="ca-top">
      <div class="qd-sum ca-sum">
        <div><b>${fmt(d.points)}</b><span>/ ${fmt(d.total)} points · ${doneAll} / ${d.tasks.length} tasks</span></div>
        <div class="ca-rank">${d.rank ? `<img src="${caIcon(d.rank)}" alt=""><span>Rank <b class="t-${d.rank.toLowerCase()}">${d.rank}</b></span>` : `<span>No rank yet</span>`}
          <span class="muted">${d.next ? `${fmt(toNext)} points to ${d.next}` : "Every task done!"}</span></div>
        <div class="bar-track"><div class="bar-fill" style="width:${pct.toFixed(1)}%"></div></div>
      </div>
      <div class="ca-tiers">${tiles}</div>
    </div>
    <div class="ca-controls">
      <div class="pill-toggle" id="ca-status">
        <button data-ca-status="open" class="${status === "open" ? "active" : ""}">To Do (${inTier.length - doneN})</button>
        <button data-ca-status="done" class="${status === "done" ? "active" : ""}">Completed (${doneN})</button>
        <button data-ca-status="all" class="${status === "all" ? "active" : ""}">All (${inTier.length})</button>
      </div>
      ${tier ? `<button type="button" class="ca-clear-tier t-${tier.toLowerCase()}" data-ca-tier="${tier}"><img src="${caIcon(tier)}" alt="">${tier} only ✕</button>` : ""}
      <input type="search" id="ca-search" placeholder="Search tasks or bosses" value="${esc(state.caSearch ?? "")}" autocomplete="off">
    </div>
    <div class="ca-grid">
      <ul class="ca-mons"></ul>
      <div class="ca-tasks"></div>
    </div>`;
  renderCaLists(rowsShown);
  box.querySelector(".ca-mons").scrollTop = monScroll;
  box.querySelector(".ca-list").scrollTop = listScroll;
}

// Boss list + task list (also redrawn alone while typing in the search box, so it keeps focus)
function renderCaLists(atLeast = 0) {
  const box = $("ca-card"), d = caData();
  const tier = CA_TIERS.includes(state.caTier) ? state.caTier : null;
  const status = state.caStatus ?? "open";
  const q = (state.caSearch ?? "").trim().toLowerCase();
  const match = (t) => (!tier || t.tier === tier) && (status === "all" || (status === "done") === t.done)
    && (!q || `${t.name} ${t.task} ${t.monster} ${t.type}`.toLowerCase().includes(q));
  const shown = d.tasks.filter(match);
  const per = new Map();
  for (const t of shown) per.set(t.monster, (per.get(t.monster) ?? 0) + 1);
  const pick = state.caPick;
  const monIcon = (m) => m.iconBoss ? `<span class="boss-icon" ${bossIconHtml(m.iconBoss)}</span>`
    : m.name === "None" ? `<span class="boss-icon"><img src="${caIcon("Grandmaster")}" alt=""></span>`
    : `<span class="boss-icon" data-initials="${esc(initialsOf(caSortName(m.name)))}"><img src="${caMonIcon(m.name)}" alt="" loading="lazy"></span>`;
  const monName = (m) => esc(m.name === "None" ? "Any Monster" : titled(m.name));
  const mons = d.mons.filter((m) => per.has(m.name) || m.name === pick);
  box.querySelector(".ca-mons").innerHTML = `
    <li><button type="button" class="ca-mon ${pick ? "" : "sel"}" data-ca-mon=""><span class="boss-icon"><img src="${caIcon("Grandmaster")}" alt=""></span>
      <span class="ca-mon-name">All Bosses</span><span class="ca-mon-n">${shown.length}</span></button></li>
    ${mons.map((m) => `<li><button type="button" class="ca-mon ${m.done >= m.all ? "full" : ""} ${pick === m.name ? "sel" : ""}" data-ca-mon="${esc(m.name)}" title="${esc(m.name)}: ${m.done} of ${m.all} tasks done">
      ${monIcon(m)}<span class="ca-mon-name">${monName(m)}</span><span class="ca-mon-n">${m.done}/${m.all}</span>
      <span class="ca-mon-bar"><i style="width:${(m.done / m.all * 100).toFixed(0)}%"></i></span></button></li>`).join("")}
    ${mons.length ? "" : `<li class="muted small ca-empty">No bosses match.</li>`}`;

  const list = pick ? shown.filter((t) => t.monster === pick) : shown;
  const m = pick && d.mons.find((x) => x.name === pick);
  const kc = m?.boss ? state.history.at(-1).bosses[m.boss] : null;
  const head = m
    ? `<div class="ca-list-head">${monIcon(m)}<div><h4>${monName(m)}</h4><span class="muted small">${m.done} / ${m.all} tasks done${kc != null ? ` · ${fmt(kc)} kill${kc === 1 ? "" : "s"}` : ""}</span></div>
        <button type="button" class="dd-close" data-ca-mon="" title="Show All Bosses">✕</button></div>`
    : `<div class="ca-list-head"><div><h4>${tier ? `${tier} tasks` : "All Tasks"}</h4><span class="muted small">${list.length} shown</span></div></div>`;
  const row = (t) => `<li class="ca-row ${t.done ? "done" : ""}" data-ca-name="${esc(t.name)}">
      <span class="dd-check">${t.done ? "✓" : ""}</span>
      <div><div class="ca-t-top"><span class="ca-t-name">${esc(titled(t.name))}</span>
          <span class="ca-badge t-${t.tier.toLowerCase()}"><img src="${caIcon(t.tier)}" alt="">${t.tier}</span></div>
        <div class="dd-task">${esc(t.task)}</div>
        <div class="ca-t-meta">${esc(t.type)}${pick ? "" : ` · ${esc(t.monster)}`}</div></div>
      <span class="ca-pts t-${t.tier.toLowerCase()}" title="${t.done ? "Earned" : "Worth"} ${t.pts} point${t.pts > 1 ? "s" : ""}"><b>+${t.pts}</b>pt${t.pts > 1 ? "s" : ""}</span>
    </li>`;
  const empty = status === "open" && !q ? "Every task here is done!" : "No tasks match.";
  // Rows are drawn CA_CHUNK at a time as the list scrolls (all 655 at once made the page lag)
  const first = Math.max(CA_CHUNK, atLeast);
  box.querySelector(".ca-tasks").innerHTML = head + `<ol class="dd-tasks ca-list">${list.length ? list.slice(0, first).map(row).join("") : `<li class="muted small ca-empty">${empty}</li>`}</ol>`;
  caRest = { list: list.slice(first), row };
  caMoreRows(0);
}
const CA_CHUNK = 60;
let caRest = { list: [], row: null };
const caMoreObserver = new IntersectionObserver((entries) => {
  if (entries.some((e) => e.isIntersecting)) caMoreRows(CA_CHUNK);
}, { rootMargin: "300px" });
// Append the next n rows; keep a sentinel at the end while rows are left
function caMoreRows(n) {
  const ol = $("ca-card").querySelector(".ca-list");
  if (!ol) return;
  ol.querySelector(".ca-more")?.remove();
  caMoreObserver.disconnect();
  if (n) ol.insertAdjacentHTML("beforeend", caRest.list.splice(0, n).map(caRest.row).join(""));
  if (!caRest.list.length) return;
  ol.insertAdjacentHTML("beforeend", `<li class="ca-more" aria-hidden="true"></li>`);
  caMoreObserver.observe(ol.querySelector(".ca-more"));
}

$("ca-card").addEventListener("click", (e) => {
  const s = e.target.closest("[data-ca-status]");
  const t = e.target.closest("[data-ca-tier]");
  const m = e.target.closest("[data-ca-mon]");
  if (s) state.caStatus = s.dataset.caStatus;
  else if (t) state.caTier = state.caTier === t.dataset.caTier ? null : t.dataset.caTier;
  else if (m) {
    state.caPick = m.dataset.caMon && state.caPick !== m.dataset.caMon ? m.dataset.caMon : null;
    renderCaLists();
    $("ca-card").querySelector(".ca-list").scrollTop = 0;
    return;
  } else return;
  savePrefs();
  renderCa();
  $("ca-card").querySelector(".ca-list").scrollTop = 0;
});
$("ca-card").addEventListener("input", (e) => {
  if (e.target.id !== "ca-search") return;
  state.caSearch = e.target.value;
  renderCaLists();
  $("ca-card").querySelector(".ca-list").scrollTop = 0;
});

// ---------- bank (OSRS Data Sync plugin) ----------
// The plugin saves your bank, gear and inventory whenever they change in game. The server reads its file
// on Refresh (bank.ps1) and keeps a line per change. Value = quantity × today's GE price.

const bankName = (id) => titled(state.bank?.names[id]?.[0] || itemName(id));
const bankPrice = (id) => bankValue(id).gp;
const bankTier = (id) => VALUE_TIERS.find(([min]) => bankPrice(id) >= min)?.[1] ?? "";

function setBank(raw) {
  if (!raw?.history?.length) { state.bank = null; return; }
  // worn / carried: equipment + inventory (bank.ps1). They count toward the value so taking gear out of
  // the bank to wear it isn't a loss. The oldest lines have neither.
  // Kind of each saved line: "plugin", "gear" (an older save that knew the gear, but whose bank copy could be
  // a little older than the gear) or "bank" (an older save with the bank only). The keys are the tags those
  // older lines carry in data\bank\history.jsonl; the saved history is never changed.
  const some = (list) => (list ?? []).filter(([, q]) => q > 0);
  const lines = raw.history.map((l) => ({ t: new Date(l.t), key: l.t, saved: l.saved, src: SAVE_KIND[l.src] ?? "bank", gearKnown: false, items: l.items,
    worn: some(l.worn), carried: some(l.carried), tracked: !!l.worn, guess: [], pouch: [], pouchSaved: l.pouch }));
  const first = lines.find((l) => l.tracked);
  // gear.t = the last Refresh that read the gear (before gear.json existed: the first tracked line)
  const liveAt = raw.gear?.t ? new Date(raw.gear.t) : first?.t ?? null;
  // gear.seen = when the plugin last wrote its file
  state.bank = { lines, cur: lines.at(-1), liveAt, gearSeen: raw.gear?.seen ? new Date(raw.gear.seen) : null, invLayout: raw.gear?.inv?.length ? raw.gear.inv : null, names: raw.items ?? {}, prices: raw.prices?.prices ?? {},
    mapping: raw.mapping ?? {}, derived: raw.derived ?? {}, slots: raw.slots ?? {}, values: new Map(),
    live: raw.live ?? null, reset: raw.reset ?? null, past: raw.past ?? null, days: raw.days ?? {} };
  // Saves from before gear was tracked: assume the gear of the first tracked save was already out, except
  // what was still in the bank then (items back in the bank since then are not out). Otherwise the value would jump
  // up the day tracking starts, for gear that was owned all along.
  if (first) {
    const ref = new Map(first.items);
    const stillOut = (out, bank) => out.map(([id, q]) => [id, q - Math.max(0, (bank.get(id) ?? 0) - (ref.get(id) ?? 0))]).filter(([, q]) => q > 0);
    for (const l of lines) if (!l.tracked) { const bank = new Map(l.items); l.worn = stillOut(first.worn, bank); l.carried = stillOut(first.carried, bank); }
  }
  // An older "gear" save's bank copy can be a few seconds older than its gear: withdraw something and put it back
  // while the bank is open, and the save has it in neither the bank nor the gear (a Mystic
  // smoke staff "lost" then "gained" a minute later). An item that dips in a "gear" save and is back in the
  // save right after (within BLIP_MS) never left: it counts as still in the bank.
  // Similarly (staff + Divine rune pouch, bank copy 2 min older than the gear, newest save): an item that
  // vanished COMPLETELY (not coins) is a blip whenever it's back in the next save, however much later that is, and
  // in the newest save it counts as still in the bank until a later save shows whether it's really gone.
  const gone = (id, now) => !now.has(id) && id !== 995 && id !== 13204;
  for (let i = 1; i < lines.length; i++) {
    const l = lines[i], next = lines[i + 1];
    if (l.src !== "gear") continue;
    const before = ownedMap(lines[i - 1]), now = ownedMap(l), after = next && ownedMap(next);
    const back = !next ? [...before].filter(([id]) => gone(id, now))
      : [...before].map(([id, q]) => [id, Math.min(q, after.get(id) ?? 0) - (now.get(id) ?? 0)])
        .filter(([id, q]) => q > 0 && (next.t - l.t <= BLIP_MS || gone(id, now)));
    if (!back.length) continue;
    const bank = new Map(l.items);
    for (const [id, q] of back) bank.set(id, (bank.get(id) ?? 0) + q);
    l.items = [...bank];
  }
  // The plugin's bank copy is "as last seen open", but the gear (worn + inventory) is saved all the time. When a
  // save still has the SAME bank copy as the save before (the bank wasn't opened in between), the gear's changes
  // came from / went to the bank: gear that appeared was taken out of it, gear that went away was put back (or
  // used up; the next bank copy shows the truth). Without this, items counted twice or not at all
  // (otherwise taking gear out shows as a large gain, then a matching loss at the next save).
  // The saved history is not changed; only how the page reads it.
  const gearMap = (l) => { const m = new Map(); for (const [id, q] of [...l.worn, ...l.carried]) m.set(id, (m.get(id) ?? 0) + q); return m; };
  for (let i = 1; i < lines.length; i++) {
    const l = lines[i], prev = lines[i - 1];
    if (l.src !== "plugin" || prev.src !== "plugin" || !l.saved || l.saved !== prev.saved) continue;
    const g0 = gearMap(prev), g1 = gearMap(l), bank = new Map(prev.items);   // prev.items: already corrected
    for (const id of new Set([...g0.keys(), ...g1.keys()])) {
      const d = (g0.get(id) ?? 0) - (g1.get(id) ?? 0);   // > 0: left the gear -> back in the bank
      if (d) bank.set(id, Math.max(0, (bank.get(id) ?? 0) + d));
    }
    l.items = [...bank].filter(([, q]) => q > 0);
  }
  // Older "bank" saves didn't know the gear. When the next save (which does know it) has exactly the same bank,
  // nothing moved in between, so the gear was the same too (otherwise a day can show -50M then +50M because
  // the ranged gear that was out counted nowhere). Marked as known gear so no "probably carried" guess is added.
  const sameBank = (a, b) => a.length === b.length && (() => { const m = new Map(a); return b.every(([id, q]) => m.get(id) === q); })();
  for (let i = 0; i < lines.length - 1; i++) {
    const l = lines[i], next = lines[i + 1];
    if (l.src !== "bank" || !(next.src === "gear" || next.src === "plugin") || !sameBank(l.items, next.items)) continue;
    l.worn = next.worn.map(([id, q]) => [id, q]); l.carried = next.carried.map(([id, q]) => [id, q]); l.gearKnown = true;
  }
  // Older "bank" saves only have the bank.
  // Whatever left the bank since the save before is assumed to be in your inventory until a save with the
  // gear shows the truth (taking things out looked like losing them).
  // Smarter, so money spent between saves doesn't show as "probably carried":
  // - no guess when the gear is known (gearKnown), or for the newest save when a later Refresh
  //   read the gear (gear.json t): nothing changed then, so no line was written, but the gear is known.
  // - coins / platinum tokens that left while GE-valued items arrived were spent on them, and items that left
  //   while coins arrived were sold (up to TRADE_SLACK × the value of what arrived, for GE price swings).
  const worth = (list) => list.reduce((s, [id, q]) => s + q * bankPrice(id), 0);
  const isCash = (id) => id === 995 || id === 13204;
  const firstGear = lines.findIndex((l) => l.src === "gear" || l.src === "plugin");
  if (firstGear >= 0) for (let i = firstGear + 1; i < lines.length; i++) {
    const l = lines[i];
    if (l.src === "gear" || l.src === "plugin" || l.gearKnown || (i === lines.length - 1 && liveAt >= l.t)) continue;
    const before = ownedMap(lines[i - 1]), now = ownedMap(l);
    const diff = (a, b) => [...a].filter(([id, q]) => q > (b.get(id) ?? 0)).map(([id, q]) => [id, q - (b.get(id) ?? 0)]);
    const lost = diff(before, now), gained = diff(now, before);
    let spent = TRADE_SLACK * worth(gained.filter(([id]) => !isCash(id)));
    let sold = TRADE_SLACK * worth(gained.filter(([id]) => isCash(id)));
    for (const [id, q] of lost.sort((a, b) => bankPrice(b[0]) - bankPrice(a[0]))) {
      const each = bankPrice(id);
      let n = 0;
      if (each > 0 && isCash(id)) { n = Math.min(q, Math.floor(spent / each)); spent -= n * each; }
      else if (each > 0) { n = Math.min(q, Math.floor(sold / each)); sold -= n * each; }
      if (q > n) l.guess.push([id, q - n]);
    }
  }
  estimatePouch(lines);
  // Today's saves and the current value use the live prices of the last Refresh; older saves are snapshots at the
  // prices of the moment they were saved (otherwise the in-game value can sit millions above the once-a-day
  // prices): bank.ps1 prices-saves.jsonl, else that day's prices-days.json (ids missing there: the day's table).
  const live = raw.live?.prices ?? null, nowDay = (raw.live?.t ?? raw.prices?.t ?? "").slice(0, 10);
  const saves = new Map((raw.saves ?? []).map((s) => [s.t, s.prices]));
  const tables = new Map(), cache = new Map();
  const tableFor = (l) => {
    const date = l.t.toISOString().slice(0, 10);
    if (date >= nowDay) return live;
    const save = saves.get(l.key), day = state.bank.days[date];
    if (!save) return day ?? null;
    if (!tables.has(l.key)) tables.set(l.key, day ? { ...day, ...save } : save);
    return tables.get(l.key);
  };
  const worthAt = (list, table) => {
    if (!table) return worth(list);
    if (!cache.has(table)) cache.set(table, new Map());
    const c = cache.get(table);
    return list.reduce((s, [id, q]) => {
      if (!c.has(id)) c.set(id, bankValue(id, table).gp);
      return s + q * c.get(id);
    }, 0);
  };
  const valueAt = (l, table) => {
    const out = worthAt(l.worn, table) + worthAt(l.carried, table) + worthAt(l.guess, table) + worthAt(l.pouch, table);
    return [worthAt(l.items, table) + out, out];
  };
  for (const l of lines) [l.value, l.outValue] = valueAt(l, tableFor(l));
  // What you own right now at today's prices (the newest save can be from an earlier day)
  [state.bank.now, state.bank.nowOut] = valueAt(state.bank.cur, live);
}
// Everything you own in one save: bank + worn + carried + the estimates (probably carried, rune pouch)
function ownedMap(line, withPouch = true) {
  const m = new Map();
  for (const [id, q] of [...line.items, ...line.worn, ...line.carried, ...line.guess, ...(withPouch ? line.pouch : [])]) m.set(id, (m.get(id) ?? 0) + q);
  return m;
}

// Rune pouch: ONLY what the OSRS Data Sync plugin reads from the game ("pouch" in a bank save). No guessing
// (the old estimate from runes leaving the bank showed 150 astral runes that weren't there).
// Saves without it (older ones, or a plugin version from before) have no pouch.
// "Probably carried": cash that left counts as spent on what arrived, up to this × its GE value (and back for sales)
const TRADE_SLACK = 1.5;
const SAVE_KIND = { plugin: "plugin", bridge: "gear", memory: "bank" };
// An item missing from one "gear" save but back within this long was only in your hands for a moment
const BLIP_MS = 10 * 60 * 1000;
function estimatePouch(lines) {
  for (const l of lines) l.pouch = l.pouchSaved ? l.pouchSaved.filter(([, q]) => q > 0) : [];
}

// What one item is worth: its GE price, or else what it's made from (bank.ps1 explains the sources):
// RuneLite's own untradeable list (Bow of faerdhinen -> the inactive bow, Purging staff -> Tormented
// synapse; several entries add up), then doses/charges, then the cheapest wiki recipe of tradeable parts.
// Recipe values under 1K are ignored (wool, buckets of water: not what people mean by "worth something").
const RECIPE_MIN = 1000;
// Off, to match the in-game bank value: the game, like RuneLite, only values untradeables
// through RuneLite's list. Doses/charges/recipes added ~4.7M, almost all of it the Divine rune pouch (recipe).
const USE_DERIVED = false;
// table: other GE prices to value with (Price moves: now / at the reset); missing ids fall back to today's
function bankValue(id, table = null) {
  const b = state.bank;
  if (!b) return { gp: itemPrice(id) };
  const key = String(id);
  let v = !table && b.values.get(key);
  if (v) return v;
  const price = (p) => table?.[p] ?? b.prices[p] ?? itemPrice(p);
  const partsGp = (parts) => parts.reduce((s, [p, q]) => s + q * price(p), 0);
  v = { gp: price(key) };
  if (!v.gp && b.mapping[key]) v = { gp: partsGp(b.mapping[key]), how: "runelite", parts: b.mapping[key] };
  else if (!v.gp && USE_DERIVED && b.derived[key]) {
    const d = b.derived[key];
    const best = d.options.map((o) => [partsGp(o), o]).filter(([gp]) => gp > 0).sort((a, c) => a[0] - c[0])[0];
    if (best && (d.via !== "recipe" || best[0] >= RECIPE_MIN)) v = { gp: best[0], how: d.via, parts: best[1] };
  }
  if (!v.gp) v = { gp: 0 };
  if (!table) b.values.set(key, v);
  return v;
}
// "valued as Tormented synapse" / "made from Ancient staff" (tooltips)
function bankValueNote(id) {
  const v = bankValue(id);
  if (!v.how) return "";
  const parts = v.parts.map(([p, q]) => (q === 1 ? "" : `${+q.toFixed(2)} × `) + bankName(p)).join(" + ");
  return v.how === "recipe" ? `made from ${parts}` : `valued as ${parts}`;
}

// Stack numbers like the game: yellow, white from 100K ("K"), green from 10M ("M")
function stackHtml(q) {
  if (q < 2) return "";
  const [txt, cls] = q >= 10e6 ? [Math.floor(q / 1e6) + "M", "m"] : q >= 100e3 ? [Math.floor(q / 1e3) + "K", "k"] : [String(q), ""];
  return `<b class="item-n ${cls}">${txt}</b>`;
}
function bankTile([id, q], cls = "") {
  const n = bankName(id), gp = bankPrice(id), note = bankValueNote(id);
  const title = `${n} · ${q.toLocaleString()}` + (gp ? (q > 1 ? ` × ${compact(gp)} = ${compact(gp * q)} GP` : ` · ${compact(gp)} GP`) : " · no value")
    + (note ? `\n≈ ${note}` : "");
  if (note) cls += " est";
  return `<span class="item ${cls} ${bankTier(id)}" title="${esc(title)}" data-initials="${esc(initialsOf(n))}"><img src="${itemIcon(id)}" alt="" loading="lazy" decoding="async">${cls ? "" : stackHtml(q)}</span>`;
}

// Worn items laid out like the game's equipment tab, carried items like its 4×7 inventory.
// Slots come from the wiki (bank.ps1 Update-BankSlots); a 2h weapon goes in the weapon slot.
const EQUIP_SLOTS = ["head", "cape", "neck", "ammo", "weapon", "body", "shield", "legs", "hands", "feet", "ring"];
function bankKitHtml(worn, carried) {
  const b = state.bank, bySlot = new Map(), loose = [];
  for (const it of worn) {
    const s = b.slots[it[0]] === "2h" ? "weapon" : b.slots[it[0]];
    if (EQUIP_SLOTS.includes(s) && !bySlot.has(s)) bySlot.set(s, it); else loose.push(it);
  }
  const slotName = (s) => s[0].toUpperCase() + s.slice(1);
  const equip = EQUIP_SLOTS.map((s) => `<div class="kit-slot" style="grid-area:${s}">${bySlot.has(s) ? bankTile(bySlot.get(s))
    : `<span class="kit-empty" title="${slotName(s)} slot (empty)"><img src="${wikiIcon(slotName(s) + "_slot.png")}" alt="" loading="lazy"></span>`}</div>`).join("");
  // Same slots as the game when the plugin sent them (b.invLayout: [slot, id, qty]), else in list order
  const cells = b.invLayout && carried === b.cur.carried ? Array.from({ length: 28 }, () => null) : [...carried];
  if (b.invLayout && carried === b.cur.carried) for (const [slot, id, q] of b.invLayout) if (slot >= 0 && slot < 28) cells[slot] = [id, q];
  const inv = Array.from({ length: Math.max(28, cells.length) }, (_, i) => (cells[i] ? bankTile(cells[i]) : `<span class="kit-cell"></span>`)).join("");
  return `<div class="bank-kit">
      <div class="kit-equip" aria-label="Equipped">${equip}</div>
      <div class="kit-inv" aria-label="Inventory">${inv}</div>
    </div>${loose.length ? `<div class="bank-out-items">${loose.map((it) => bankTile(it)).join("")}</div>` : ""}`;
}

function renderBank() {
  const card = $("bank-card"), b = state.bank;
  card.hidden = !b;
  if (!b) return;
  const cur = b.cur.items;
  const coins = [...cur, ...b.cur.carried].reduce((s, [id, q]) => s + (id === 995 ? q : id === 13204 ? q * 1000 : 0), 0);
  const out = [...b.cur.worn, ...b.cur.carried, ...b.cur.guess, ...b.cur.pouch];
  // Most valuable: live GE price from the last Refresh, not the once-a-day one
  const stack = ([id, q]) => q * (b.live ? bankValue(id, b.live.prices).gp : bankPrice(id));
  const best = cur.reduce((a, it) => (stack(it) > stack(a) ? it : a), cur[0]);
  const unpriced = cur.filter(([id]) => !bankPrice(id)).length;
  const smart = cur.filter(([id]) => bankValue(id).how).length;
  const stat = (label, value, sub = "") => `<div class="clog-stat"><span>${label}</span><b>${value}</b>${sub ? `<small>${sub}</small>` : ""}</div>`;
  card.innerHTML = `
    <div class="card-head">
      <div class="clog-head"><span class="clog-icon"><img src="${wikiIcon("Bank_icon.png")}" alt=""></span>
        <div><h3>Bank</h3><p class="muted small">${cur.length.toLocaleString()} items · from OSRS Data Sync (RuneLite) · bank last seen ${esc(b.cur.saved)}</p></div></div>
      <div class="card-head-tools" id="bank-pin">${secPeriodBtnHtml("bank")}</div>
    </div>
    <div class="bank-body">
      <div class="bank-top">
       <div class="bank-summary">
        <div class="bank-hero">
          <div class="clog-gp-top">
            <div><span>Bank Value${out.length ? " (Incl. Worn &amp; Carried)" : ""}</span><b title="${Math.round(b.now).toLocaleString()} GP">${compact(b.now)} GP</b></div>
            <div class="clog-period" id="bank-period"></div>
          </div>
          <div id="bank-spark">${bankSparkHtml(secPeriod("bank"))}</div>
        </div>
        <div class="clog-stats">
          ${stat("Coins", compact(coins), "incl. platinum tokens")}
          ${stat("Items", cur.length.toLocaleString(), `${smart.toLocaleString()} valued by parts · ${unpriced.toLocaleString()} no value`)}
          ${best ? `<div class="clog-stat bank-best"><span>Most Valuable</span>${bankTile(best, "faint")}<b title="${Math.round(stack(best)).toLocaleString()} GP${b.live ? " · live price at the last Update" : ""}">${compact(stack(best))}</b><small>${esc(bankName(best[0]))}${best[1] > 1 ? ` × ${compact(best[1])}` : ""}</small></div>` : ""}
        </div>
       </div>
        <div class="bank-out">
          <div class="bank-out-head"><h4>Equipped &amp; Inventory</h4>${out.length ? `<b>${compact(b.nowOut)} GP</b>` : ""}</div>
          ${out.length || b.liveAt ? bankKitHtml(b.cur.worn, b.cur.carried) : ""}
          ${b.cur.guess.length ? `<div class="kit-pouch" title="RuneLite wasn't running at the last Update, so these left the bank and are counted as still carried until it can check">
            <span class="muted small">≈ Probably carried</span><div class="bank-out-items">${b.cur.guess.map((it) => bankTile(it)).join("")}</div></div>` : ""}
          ${b.cur.pouch.length ? `<div class="kit-pouch">
            <span class="muted small">In your rune pouch${b.cur.carried.some(([id]) => /rune pouch/i.test(bankName(id))) ? "" : " (pouch is in the bank)"}</span><div class="bank-out-items">${b.cur.pouch.map((it) => bankTile(it)).join("")}</div></div>` : ""}
        </div>
      </div>
      <div class="bank-bottom">
      <div class="bank-right">
        <div class="bank-tools">
          <h4>Bank Items <span class="bank-count" id="bank-count"></span></h4>
          <input type="search" id="bank-search" placeholder="Search your bank…" value="${esc(state.bankQuery ?? "")}" autocomplete="off">
          <div class="pill-toggle" id="bank-sort">
            ${[["bank", "Bank Order"], ["value", "Value"], ["name", "A–Z"]].map(([k, l]) => `<button data-bank-sort="${k}" class="${(state.bankSort ?? "bank") === k ? "active" : ""}">${l}</button>`).join("")}
          </div>
        </div>
        <div class="bank-items" id="bank-items"></div>
      </div>
      <div class="bank-changes"><h4>Changes</h4>${bankChangesHtml()}</div>
      </div>
      <div class="bank-moves" id="bank-moves"></div>
    </div>`;
  renderBankItems();
  renderBankPeriod(ctx());
}

// Change in bank value over the selected period (render(): also on period clicks)
function renderBankPeriod(c) {
  const { base, period } = secCtx("bank", c); // its own period when "Own Period" is on
  renderBankMoves(period);
  if ($("bank-spark") && state.bank) $("bank-spark").innerHTML = bankSparkHtml(period); // the graph follows the period
  const el = $("bank-period"), b = state.bank;
  if (!el || !b) return;
  const at = [...b.lines].reverse().find((l) => l.t <= base.time);
  if (!at) {
    el.className = "clog-period";
    el.innerHTML = `Tracked since ${b.lines[0].t.toLocaleDateString(undefined, { month: "short", day: "numeric" })}`;
    return;
  }
  const d = b.now - at.value;
  el.className = `clog-period ${d > 0 ? "pos" : d < 0 ? "neg" : ""}`;
  el.innerHTML = `${d ? (d > 0 ? "+" : "−") + compact(Math.abs(d)) + " GP" : "No change"} <span>· ${esc(periodLabel(period))}</span>`;
}

// Step line of the bank value at each change, over the selected period (like the collection log graphs)
function bankSparkHtml(period = secPeriod("bank")) {
  const all = state.bank.lines;
  if (all.length < 2) return `<p class="muted small bank-spark-empty">A value graph appears here once your bank changes.</p>`;
  const W = 300, H = 80, t0 = +graphStart(all[0].t, period), t1 = Math.max(Date.now(), t0 + 1); // the selected period
  const first = [...all].reverse().find((l) => +l.t <= t0) ?? all[0];
  const s = [{ t: new Date(t0), value: first.value }, ...all.filter((l) => +l.t > t0)];
  // Newest save from an earlier day: today's prices step in at the start of today (UTC, like the price days)
  const today = new Date(new Date().toISOString().slice(0, 10)), b = state.bank;
  if (b.now !== s.at(-1).value) s.push({ t: new Date(Math.max(+today, +s.at(-1).t, t0)), value: b.now });
  const vals = s.map((p) => p.value), lo = Math.min(...vals), hi = Math.max(lo + 1, ...vals);
  const X = (t) => ((t - t0) / (t1 - t0)) * W, Y = (v) => H - 4 - ((v - lo) / (hi - lo)) * (H - 12);
  const pts = [];
  s.forEach((p, i) => { if (i) pts.push([X(+p.t), Y(s[i - 1].value)]); pts.push([X(+p.t), Y(p.value)]); });
  pts.push([W, Y(s.at(-1).value)]);
  const line = pts.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  // A node for every saved bank in the window
  const nodes = [];
  all.forEach((l, i) => { if (+l.t >= t0) nodes.push({ x: X(+l.t), t: l.t, value: l.value, d: i ? l.value - all[i - 1].value : null }); });
  return `<svg class="clog-spark spark-hover" data-spark="bank" viewBox="0 0 ${W} ${H}" role="img" aria-label="Bank value over time, ${compact(lo)} to ${compact(hi)} GP">
      <defs><linearGradient id="bankFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4ade80" stop-opacity=".25"/><stop offset="1" stop-color="#4ade80" stop-opacity="0"/></linearGradient></defs>
      <polygon points="0,${H} ${line} ${W},${H}" fill="url(#bankFill)"/>
      <polyline points="${line}" fill="none" stroke="#4ade80" stroke-width="2" stroke-linejoin="round"/>
      ${sparkNodesHtml("bank", nodes, Y, H, { label: "Bank Value", first: "First Saved Bank", fmt: gpFull, fmtD: gpChange })}
    </svg>
    <div class="clog-axis"><span>${axisDate(new Date(t0))}</span><span>Now · ${compact(s.at(-1).value)} GP</span></div>`;
}


// What came in / went out between saved banks, newest first (moving items around isn't a change)
const GROUP_TOP = 4;
function bankChangesHtml() {
  const b = state.bank, rows = [];
  for (let i = b.lines.length - 1; i > 0 && rows.length < 8; i--) {
    // Bank, worn and carried as one pile: wearing or withdrawing something is not a change
    const prev = ownedMap(b.lines[i - 1]), now = ownedMap(b.lines[i]), diff = [];
    for (const [id, q] of now) if (q !== (prev.get(id) ?? 0)) diff.push([id, q - (prev.get(id) ?? 0)]);
    for (const [id, q] of prev) if (!now.has(id)) diff.push([id, -q]);
    if (!diff.length) continue;
    diff.sort((a, c) => Math.abs(c[1] * bankPrice(c[0])) - Math.abs(a[1] * bankPrice(a[0])) || Math.abs(c[1]) - Math.abs(a[1]));
    // At today's prices like the Gained/Lost totals (the saves' own values can be from days with other prices)
    const net = diff.reduce((s, [id, d]) => s + d * bankPrice(id), 0), t = b.lines[i].t;
    // Gained and Lost apart, each with its total and biggest first; GROUP_TOP of
    // each show, the rest open with "+N more"
    const chip = ([id, d], k) => `<span class="clog-item bank-d ${d > 0 ? "pos" : "neg"}${k >= GROUP_TOP ? " extra" : ""}" title="${esc(bankName(id))} ${d > 0 ? "+" : "−"}${Math.abs(d).toLocaleString()}${bankPrice(id) ? ` (${compact(Math.abs(d) * bankPrice(id))} GP)` : ""}">${bankTile([id, Math.abs(d)], "faint")}${d > 0 ? "+" : "−"}${compact(Math.abs(d))} ${esc(bankName(id))}</span>`;
    const group = (sign, label) => {
      const list = diff.filter(([, d]) => Math.sign(d) === sign);
      if (!list.length) return "";
      const gp = list.reduce((s, [id, d]) => s + Math.abs(d) * bankPrice(id), 0);
      return `<div class="bank-grp ${sign > 0 ? "pos" : "neg"}"><span class="bank-grp-h">${label} <b>${sign > 0 ? "+" : "−"}${compact(gp)}</b> · ${list.length}</span>
        <div class="bank-grp-items">${list.map(chip).join("")}</div></div>`;
    };
    const hidden = Math.max(0, diff.filter(([, d]) => d > 0).length - GROUP_TOP) + Math.max(0, diff.filter(([, d]) => d < 0).length - GROUP_TOP);
    const open = state.bankOpen?.has(+t);
    rows.push(`<div class="clog-day${open ? " open" : ""}">
      <div class="clog-date"><b>${t.toLocaleDateString(undefined, { month: "short", day: "numeric" })}</b><span>${t.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })}</span></div>
      <div class="clog-items">${group(1, "Gained")}${group(-1, "Lost")}${hidden ? `<button type="button" class="bank-more-n" data-bank-day="${+t}" aria-expanded="${!!open}"><span class="more">+${hidden} more</span><span class="less">Show Less</span></button>` : ""}</div>
      <b class="bank-net ${net > 0 ? "pos" : net < 0 ? "neg" : ""}">${net ? (net > 0 ? "+" : "−") + compact(Math.abs(net)) : "±0"}</b>
    </div>`);
  }
  return rows.length ? `<div class="bank-chg-list">${rows.join("")}</div>`
    : `<p class="muted small">Items you gain or lose show up here after your bank changes in game and you press Update.</p>`;
}

// Price moves for the selected period, so volatile items stand out.
// Everything you own now (bank + worn + carried + the estimates) valued at the GE prices of the last Refresh
// (bank.ps1 prices-live.json) against the period's start: Today = the hour before the daily reset
// (prices-reset.json), other periods = the 24h average of the day before the period starts (prices-past.json,
// downloaded once per day on Refresh). Split into what's gaining and what's losing you money, biggest first.
// Untradeables move with the parts they're valued by (Bow of faerdhinen = the inactive bow).
// Drawn by render() (period clicks); the lists have a fixed height so switching never changes the page height.
function renderBankMoves(period = secPeriod("bank")) {
  const el = $("bank-moves");
  if (el && state.bank) el.innerHTML = bankMovesHtml(period);
}
function bankMovesHtml(period = secPeriod("bank")) {
  const b = state.bank;
  const label = periodLabel(period);
  const day = (d) => d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: d.getFullYear() === new Date().getFullYear() ? undefined : "numeric" });
  const past = period === "day" ? null : b.past?.[period];
  const since = period === "day" ? "the daily reset" : past ? day(new Date(past.date + "T00:00")) : "";
  // The period comes from the top bar's picker (sticky, always in reach; it replaced the copy of the period
  // buttons that used to sit here.
  const head = (extra = "") => `<div class="bank-moves-head"><h3>Price Moves <span>· ${esc(label)}</span></h3>${extra}</div>`;
  const empty = (msg) => `${head()}<div class="bank-moves-cols"><div class="move-list move-empty"><p class="muted small">${msg}</p></div></div>`;
  if (!b.live) return empty("Press Update to see which of your items went up or down in price.");
  const then = period === "day" ? b.reset?.prices ?? b.prices : past?.prices;
  if (!then) return empty(`Press Update to load the GE prices from the start of this period (${esc(label.toLowerCase())}).`);
  const moves = [];
  for (const [id, q] of ownedMap(b.cur)) {
    if (q <= 0 || id === 995 || id === 13204) continue;
    const a = bankValue(id, then).gp, z = bankValue(id, b.live.prices).gp;
    if (a && z && a !== z) moves.push({ id, q, a, z, d: q * (z - a) });
  }
  // Search: filters the Gaining / Losing lists; the total at the top stays for everything you own
  const q = (state.movesQuery ?? "").trim().toLowerCase();
  const match = (m) => !q || bankName(m.id).toLowerCase().includes(q);
  const sum = (list) => list.reduce((s, m) => s + m.d, 0), net = sum(moves);
  const up = moves.filter((m) => m.d > 0 && match(m)).sort((x, y) => y.d - x.d), down = moves.filter((m) => m.d < 0 && match(m)).sort((x, y) => x.d - y.d);
  const signed = (n) => (n > 0 ? "+" : n < 0 ? "−" : "±") + compact(Math.abs(n));
  const pctOf = (a, z) => { const p = ((z - a) / a) * 100; return (p > 0 ? "+" : p < 0 ? "−" : "±") + Math.abs(p).toFixed(Math.abs(p) < 10 ? 1 : 0) + "%"; };
  const row = (m) => `<div class="move-row" title="${esc(`${bankName(m.id)} · ${compact(m.a)} → ${compact(m.z)} GP each${m.q > 1 ? ` · you have ${m.q.toLocaleString()}` : ""}`)}">
      ${bankTile([m.id, m.q], "faint")}
      <div class="move-name"><b>${esc(bankName(m.id))}</b><small>${compact(m.a)} → ${compact(m.z)} GP <span class="${m.d > 0 ? "pos" : "neg"}">${pctOf(m.a, m.z)}</span>${m.q > 1 ? ` · × ${compact(m.q)}` : ""}</small></div>
      <b class="bank-net ${m.d > 0 ? "pos" : "neg"}">${signed(m.d)}</b>
    </div>`;
  const side = (list, name, cls) => `<div class="bank-grp ${cls}"><span class="bank-grp-h">${name} <b>${signed(sum(list))}</b> · ${list.length}</span>
      <div class="move-list">${list.length ? list.map(row).join("") : `<p class="muted small">${q ? `No items match “${esc(q)}”.` : `Nothing you own is ${cls === "pos" ? "up" : "down"} since ${esc(since)}.`}</p>`}</div></div>`;
  // What the items that moved were worth then vs. now
  const was = moves.reduce((s, m) => s + m.q * m.a, 0), now = was + net;
  const at = new Date(b.live.t).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  const vs = period === "day" ? "before today's reset" : esc(since);
  return `${head(`<input type="search" id="moves-search" placeholder="Search price moves…" value="${esc(state.movesQuery ?? "")}" autocomplete="off">
      <div class="moves-total">
        <b class="bank-net ${net > 0 ? "pos" : net < 0 ? "neg" : ""}" title="What everything you own gained or lost in price since ${esc(since)}">${signed(net)} GP</b>
        ${was ? `<small>${compact(was)} → ${compact(now)} GP · <span class="${net > 0 ? "pos" : net < 0 ? "neg" : ""}">${pctOf(was, now)}</span></small>` : ""}
      </div>`)}
      <div class="bank-moves-cols">${side(up, "Gaining", "pos")}${side(down, "Losing", "neg")}</div>
      <p class="muted small moves-note">Prices at ${at} vs. ${vs}</p>`;
}

// Item grid: drawn BANK_CHUNK tiles at a time as you scroll the box (an 800-item bank is a lot of elements)
const BANK_CHUNK = 160;
let bankRest = [];
const bankMoreObserver = new IntersectionObserver((entries) => {
  if (entries.some((e) => e.isIntersecting)) bankMoreTiles(BANK_CHUNK);
}, { rootMargin: "300px" });
function bankMoreTiles(n) {
  const box = $("bank-items");
  if (!box) return;
  box.querySelector(".bank-more")?.remove();
  bankMoreObserver.disconnect();
  if (n) box.insertAdjacentHTML("beforeend", bankRest.splice(0, n).map((it) => bankTile(it)).join(""));
  if (!bankRest.length) return;
  box.insertAdjacentHTML("beforeend", `<span class="bank-more" aria-hidden="true"></span>`);
  bankMoreObserver.observe(box.querySelector(".bank-more"));
}
function renderBankItems() {
  const box = $("bank-items"), b = state.bank;
  if (!box || !b) return;
  const q = (state.bankQuery ?? "").trim().toLowerCase();
  let list = b.cur.items.filter(([id]) => !q || bankName(id).toLowerCase().includes(q));
  if (state.bankSort === "value") list.sort((a, c) => c[1] * bankPrice(c[0]) - a[1] * bankPrice(a[0]));
  else if (state.bankSort === "name") list.sort((a, c) => bankName(a[0]).localeCompare(bankName(c[0])));
  box.innerHTML = list.length ? "" : `<p class="muted small">No items match “${esc(q)}”.</p>`;
  bankRest = list;
  bankMoreTiles(BANK_CHUNK);
  const worth = list.reduce((s, [id, n]) => s + n * bankPrice(id), 0);
  $("bank-count").textContent = q ? `· ${list.length.toLocaleString()} of ${b.cur.items.length.toLocaleString()} · ${compact(worth)} GP` : "";
}

$("bank-card").addEventListener("click", (e) => {
  // "+N more" in Changes: show every item of that save (remembered until the page reloads). The page never
  // moves (the button is left out of pinSpot: it changes place inside the row, and following it would scroll
  // the window); only the Changes box scrolls, and only to keep the row's top in view after "Show Less".
  const more = e.target.closest("[data-bank-day]");
  if (more) {
    const day = more.closest(".clog-day"), list = day.closest(".bank-chg-list"), key = +more.dataset.bankDay;
    const open = !day.classList.contains("open"), keep = list.scrollTop;
    state.bankOpen ??= new Set();
    state.bankOpen[open ? "add" : "delete"](key);
    day.classList.toggle("open", open);
    more.setAttribute("aria-expanded", open);
    list.scrollTop = keep;
    const above = list.getBoundingClientRect().top - day.getBoundingClientRect().top;
    if (above > 0) list.scrollTop -= above;
    return;
  }
  const s = e.target.closest("[data-bank-sort]");
  if (!s) return;
  state.bankSort = s.dataset.bankSort;
  savePrefs();
  setActive($("bank-sort"), s);
  renderBankItems();
  $("bank-items").scrollTop = 0;
});
$("bank-card").addEventListener("input", (e) => {
  if (e.target.id === "moves-search") {
    // The whole Price moves box is redrawn: put the cursor back where it was
    state.movesQuery = e.target.value;
    const at = e.target.selectionStart;
    renderBankMoves();
    const box = $("moves-search");
    box?.focus({ preventScroll: true }); box?.setSelectionRange(at, at);
    return;
  }
  if (e.target.id !== "bank-search") return;
  state.bankQuery = e.target.value;
  renderBankItems();
  $("bank-items").scrollTop = 0;
});

// ---------- kills & loot (RuneLite's Loot Tracker, via the OSRS Data Sync plugin) ----------
// Every monster, chest, clue and pickpocket that gave a drop: kills, total drops and their GE value now.

// Tabs. Loot Tracker type NPC is split: "BOSS" = a boss the official hiscores track (or its CA alias, e.g.
// Corrupted Hunllef -> The Corrupted Gauntlet), "NPC" = every other monster
const KILL_TYPES = [["BOSS", "Bosses"], ["NPC", "Monsters"], ["EVENT", "Chests & Clues"], ["PICKPOCKET", "Pickpocketing"], ["PLAYER", "Players"]];
const killTypeName = (t) => ({ BOSS: "Boss", NPC: "Monster" })[t] ?? KILL_TYPES.find(([k]) => k === t)?.[1] ?? "Other";
// Bosses the hiscores only count as a group (raid / duo), so their names never match a hiscores boss
const KILL_EXTRA_BOSSES = new Set(["Dusk", "Dawn", "Akkha", "Ba-Ba", "Kephri", "Zebak", "Tumeken's Warden", "Elidinis' Warden",
  "Great Olm", "Verzik Vitur", "Dagannoth Rex", "Dagannoth Prime", "Dagannoth Supreme"]);
function killIsBoss(s) {
  const bosses = state.history.at(-1)?.bosses ?? {};
  return BOSS_NO_LOOT_FALLBACK.has(s.name) || (s.type === "NPC" && (s.name in bosses || (CA_BOSS_ALIAS[s.name] ?? "") in bosses || KILL_EXTRA_BOSSES.has(s.name)));
}
const killGroup = (s) => (killIsBoss(s) ? "BOSS" : s.type);
// "per kill" / "per open" / ... for a tab (All mixes them: "per kill or loot")
const killUnit = (t) => ({ BOSS: "kill", NPC: "kill", PLAYER: "kill", EVENT: "open", PICKPOCKET: "pickpocket" })[t] ?? "kill or loot";
const killPrice = (id) => (+id === 995 ? 1 : +id === 13204 ? 1000 : bankPrice(id));
const KILL_SORTS = [["kills", "Kills"], ["value", "Loot"], ["recent", "Recent"], ["name", "A–Z"]];

function killSources() {
  if (state.killSrc) return state.killSrc;
  const list = [];
  for (const [type, byName] of Object.entries(state.plugin?.kills?.lootTracker ?? {})) {
    for (const [name, r] of Object.entries(byName)) {
      const drops = Object.entries(r.drops ?? {}).map(([id, q]) => [+id, q]).filter(([, q]) => q > 0);
      let value = 0, best = null;
      for (const [id, q] of drops) {
        value += killPrice(id) * q;
        if (best == null || killPrice(id) > killPrice(best)) best = id;
      }
      list.push({ key: `${type}|${name}`, type, name, kills: hiscoresKills(name) ?? r.kills ?? 0, value, best: best && killPrice(best) ? best : null, drops,
        first: r.first ? new Date(r.first) : null, last: r.last ? new Date(r.last) : null });
    }
  }
  return (state.killSrc = list);
}

// The monster's own picture (OSRS Wiki, saved on Refresh: icons\npc), else the boss icon when the hiscores know the
// name, the clue scroll for clues, else the best drop (chests, clues, ... have no monster picture)
const npcSlug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
function killIconHtml(s) {
  if (s.type !== "EVENT" && (state.npcIcons ??= new Set(state.plugin?.npcIcons ?? [])).has(npcSlug(s.name)))
    return `<span class="cat-ic npc-ic" data-initials="${esc(initialsOf(s.name))}"><img src="${icon(`/icons/npc/${npcSlug(s.name)}.png`)}" alt="" loading="lazy"></span>`;
  const tier = s.name.match(/^Clue Scroll \((\w+)\)$/i)?.[1]?.toLowerCase();
  if (tier) return `<span class="cat-ic"><img src="${gameIcon("cluescrolls" + tier)}" alt="" loading="lazy"></span>`;
  const bosses = state.history.at(-1)?.bosses ?? {};
  if (s.name in bosses) return `<span class="cat-ic" ${bossIconHtml(s.name)}</span>`;
  if ((CA_BOSS_ALIAS[s.name] ?? "") in bosses) return `<span class="cat-ic" ${bossIconHtml(CA_BOSS_ALIAS[s.name])}</span>`; // Corrupted Hunllef, ...
  const id = s.best ?? s.drops?.[0]?.[0];
  return `<span class="cat-ic" data-initials="${esc(initialsOf(s.name))}">${id != null ? `<img src="${itemIcon(id)}" alt="" loading="lazy">` : esc(initialsOf(s.name))}</span>`;
}

function renderKills() {
  const card = $("kills-card");
  const all = killSources();
  card.hidden = !all.length;
  if (!all.length) return;
  const types = KILL_TYPES.filter(([t]) => all.some((s) => killGroup(s) === t));
  if (all.some((s) => !KILL_TYPES.some(([t]) => t === killGroup(s)))) types.push(["OTHER", "Other"]);
  const tabs = [["all", "All"], ...types];
  if (!tabs.some(([t]) => t === state.killsTab)) state.killsTab = types.some(([t]) => t === "NPC") ? "NPC" : "all";
  const inTab = killsInTab();
  const hiddenN = killsInTabAll().length - inTab.length;
  if (!hiddenN) state.killsShowHidden = false;
  const kills = inTab.reduce((s, x) => s + x.kills, 0), value = inTab.reduce((s, x) => s + x.value, 0);
  const best = inTab.filter((x) => x.best != null).sort((a, b) => killPrice(b.best) - killPrice(a.best))[0];
  // "Most ..." cards, one per kind of source, each with its picture. Monsters and bosses only count kills;
  // chests & clues and pickpocketing get their own (they aren't kills)
  const most = (f) => inTab.filter(f).sort((a, b) => b.kills - a.kills)[0];
  const tops = [
    ["Most Killed", most((s) => killGroup(s) === "NPC"), "kills"],
    ["Top Boss", most((s) => killGroup(s) === "BOSS"), "kills"],
    ["Most Opened", most((s) => killGroup(s) === "EVENT"), "opened"],
    ["Most Pickpocketed", most((s) => s.type === "PICKPOCKET"), "times"],
  ].filter(([, s]) => s);
  const countLabel = { BOSS: "Boss Kills", NPC: "Kills", EVENT: "Opened", PICKPOCKET: "Pickpockets", PLAYER: "Kills" }[state.killsTab] ?? "Times Looted";
  const countIcon = { BOSS: wikiIcon("Combat_icon.png"), NPC: skillIcon("Attack"), PLAYER: skillIcon("Attack"), EVENT: gameIcon("cluescrollsall"), PICKPOCKET: skillIcon("Thieving") }[state.killsTab] ?? skillIcon("Slayer");
  const avg = kills ? value / kills : 0;
  const log = state.killsView === "log";
  card.innerHTML = `
    <div class="card-head">
      <div class="clog-head"><span class="clog-icon"><img src="${skillIcon("Slayer")}" alt=""></span>
      <div><h3>Kills &amp; Loot</h3></div></div>
      <div class="pill-toggle" id="kill-tabs">${tabs.map(([t, l]) => `<button data-kill-tab="${t}" class="${t === state.killsTab ? "active" : ""}">${l}</button>`).join("")}</div>
    </div>
    <div class="clog-stats kill-stats">
      <div class="clog-stat kill-top"><span class="cat-ic"><img src="${countIcon}" alt=""></span><div><span>${esc(countLabel)}</span><b>${kills.toLocaleString()}</b><small>${inTab.length.toLocaleString()} different</small></div></div>
      <div class="clog-stat kill-top"><span class="cat-ic"><img src="${itemIcon(995)}" alt=""></span><div><span>Loot Value</span><b class="pos">${compact(value)}</b><small>GE Price Now</small></div></div>
      <div class="clog-stat kill-top"><span class="cat-ic avg-ic"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20V10M10 20V6M16 20v-8M22 20H2"/><path d="M3 9.5 9.5 6l6.5 5.5L21 7" class="avg-line"/></svg></span><div><span>Average Loot</span><b class="pos">${avg ? compact(avg) : "–"}</b><small>per ${killUnit(state.killsTab)}</small></div></div>
      <div class="clog-stat kill-top">${best ? `<span class="cat-ic"><img src="${itemIcon(best.best)}" alt=""></span>` : ""}<div><span>Best Drop</span><b class="kill-stat-name">${best ? esc(bankName(best.best)) : "–"}</b><small>${best ? `${compact(killPrice(best.best))} · from ${esc(best.name)}` : ""}</small></div></div>
      ${tops.map(([label, s, unit]) => `<div class="clog-stat kill-top">
      ${killIconHtml(s)}<div><span>${label}</span><b class="kill-stat-name">${esc(titled(s.name))}</b><small>${s.kills.toLocaleString()} ${unit}</small></div>
    </div>`).join("")}
    </div>
    <div class="bank-tools kill-tools">
      <div class="kill-view-wrap">
        <div class="pill-toggle kill-view" id="kill-view">${[["sources", "Sources"], ["log", "Drop Log"]].map(([v, l]) =>
          `<button data-kill-view="${v}" class="${(state.killsView ?? "sources") === v ? "active" : ""}">${l}</button>`).join("")}</div>
        <span class="bank-count" id="kill-count"></span>
      </div>
      <input type="search" id="kill-search" placeholder="${log ? "Search monsters or drops…" : "Search monsters…"}" value="${esc(state.killsQuery ?? "")}" autocomplete="off">
      ${hiddenN && !log ? `<button type="button" class="kill-hidden-btn ${state.killsShowHidden ? "active" : ""}" data-kill-hidden-view aria-pressed="${!!state.killsShowHidden}" title="Monsters you hid in this tab">${EYE_OFF}Hidden ${hiddenN}</button>` : ""}
      ${log ? "" : `<div class="pill-toggle" id="kill-sort">${KILL_SORTS.map(([k, l]) => `<button data-kill-sort="${k}" class="${(state.killsSort ?? "kills") === k ? "active" : ""}">${l}</button>`).join("")}</div>`}
    </div>
    <div class="cat-list kill-list" id="kill-list"></div>`;
  renderKillList();
}
// Monsters the user chose to hide (eye button): left out of the list, the totals and the feed. This device only.
const killHidden = (key) => (state.killsHidden ?? []).includes(key);
const killsInTabAll = () => killSources().filter((s) => state.killsTab === "all" || killGroup(s) === state.killsTab
  || (state.killsTab === "OTHER" && !KILL_TYPES.some(([t]) => t === killGroup(s))));
const killsInTab = () => killsInTabAll().filter((s) => !killHidden(s.key));
const EYE_OFF = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 3l18 18M10.6 5.1A10 10 0 0 1 12 5c5 0 9 4.5 10 7a13 13 0 0 1-3.2 4.3M6.6 6.6A13 13 0 0 0 2 12c1 2.5 5 7 10 7a10 10 0 0 0 4.4-1"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>`;
const EYE = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12c1-2.5 5-7 10-7s9 4.5 10 7c-1 2.5-5 7-10 7S3 14.5 2 12z"/><circle cx="12" cy="12" r="3"/></svg>`;

// ---- Drop log: every kill / open / pickpocket the plugin saved (loot.jsonl), newest first,
// grouped by day, with what dropped. Follows the tab, the search (monster or item name), hidden monsters and the
// period picker. Values are what the drop was worth when it dropped. Starts from when the plugin began saving drops.
// "gap" lines (server Update-PluginLootGaps): kills done while the plugin wasn't running (normal RuneLite client),
// found from the Loot Tracker totals: one row for "kills" kills, their drops summed (null = not known, from before
// the totals were kept), valued at today's GE price.
const KILL_LOG_PAGE = 100;
function killLogEvents() {
  if (state.killLog) return state.killLog;
  const out = [];
  for (const d of state.plugin?.drops ?? []) {
    if (!d?.source || !d.t) continue;
    const known = !d.gap || Array.isArray(d.items);
    const items = (d.items ?? []).filter((it) => Array.isArray(it) && it[1] > 0)
      .map(([id, q, each]) => [id, q, each || killPrice(id)]).sort((a, b) => b[1] * b[2] - a[1] * a[2]);
    const value = d.gap ? items.reduce((s, [, q, each]) => s + q * each, 0) : d.value ?? 0;
    // Only a Gauntlet chest holding crystal shards is a kill; Doom rewards never count (hiscores only)
    const isKill = GAUNTLET_LOOT.has(d.source) ? !d.gap && items.some(([id]) => id === CRYSTAL_SHARD) : !BOSS_NO_LOOT_FALLBACK.has(d.source);
    out.push({ t: new Date(d.t), key: `${d.type}|${d.source}`, type: d.type, name: d.source, value, kc: isKill ? d.kc ?? null : null, items,
      kills: isKill ? Math.max(1, d.kills ?? 1) : 0, gap: !!d.gap, known });
  }
  return (state.killLog = out.sort((a, b) => b.t - a.t));
}

function renderKillLog(list) {
  const q = (state.killsQuery ?? "").trim().toLowerCase();
  const start = periodStart(state.period);
  const all = killLogEvents();
  // A monster's exact name (e.g. from a Recent activity jump) shows only that monster, not "Guard dog" or items
  const exact = q && all.some((e) => e.name.toLowerCase() === q);
  const rows = all.filter((e) => e.t >= start && !killHidden(e.key)
    && (state.killsTab === "all" || killGroup(e) === state.killsTab || (state.killsTab === "OTHER" && !KILL_TYPES.some(([t]) => t === killGroup(e))))
    && (!q || (exact ? e.name.toLowerCase() === q
      : e.name.toLowerCase().includes(q) || e.items.some(([id]) => bankName(id).toLowerCase().includes(q)))));
  const total = rows.reduce((s, e) => s + e.value, 0), killsN = rows.reduce((s, e) => s + e.kills, 0);
  // "kills" / "opens" / "pickpockets" for the tab ("drops" when tabs are mixed)
  const unit = { BOSS: "kill", NPC: "kill", PLAYER: "kill", EVENT: "open", PICKPOCKET: "pickpocket" }[state.killsTab] ?? "drop";
  const units = (c) => `${c.toLocaleString()} ${c === 1 ? unit : unit + "s"}`;
  $("kill-count").textContent = rows.length ? `${units(killsN)} · ${compact(total)} loot` : "";
  if (!rows.length) {
    const since = all.length ? all.at(-1).t.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }) : null;
    list.innerHTML = `<p class="muted small kill-none">${q ? "Nothing matches." : `No drops ${state.period === "all" ? "saved yet" : `in ${esc(periodLabel().toLowerCase())}`}.`}${since ? ` The drop log starts ${since}.` : " The drop log starts the next time you get a drop."}</p>`;
    return;
  }
  const n = state.killLogN ?? KILL_LOG_PAGE;
  const srcByKey = new Map(killSources().map((s) => [s.key, s]));
  const dayName = (d) => localDayName(d, true);
  // Per day: how many and how much, for the day headers
  const perDay = new Map();
  for (const e of rows) {
    const k = localDayKey(e.t), p = perDay.get(k) ?? { n: 0, v: 0 };
    p.n += e.kills; p.v += e.value; perDay.set(k, p);
  }
  // Column labels, pinned above the day headers while scrolling
  const who = ["BOSS", "NPC"].includes(state.killsTab) ? "Monster" : "Source";
  let html = `<div class="klog-head" aria-hidden="true"><span>Time</span><span></span><span>${who}</span><span>Drops</span><span>Value</span></div>`, lastDay = null;
  for (const e of rows.slice(0, n)) {
    const k = localDayKey(e.t);
    if (k !== lastDay) {
      const p = perDay.get(k);
      html += `<div class="klog-day"><span>${esc(dayName(e.t))}</span><small>${units(p.n)} · <b>${compact(p.v)}</b></small></div>`;
      lastDay = k;
    }
    const src = srcByKey.get(e.key) ?? { type: e.type, name: e.name, best: e.items[0]?.[0] ?? null, drops: e.items };
    const shown = e.items.slice(0, 8), more = e.items.length - shown.length;
    const best = e.items[0] ? e.items[0][1] * e.items[0][2] : 0;
    const kUnit = killUnit(killGroup(e)), kWord = e.kills === 1 ? kUnit : kUnit + "s";
    html += `<button type="button" class="klog-row ${best >= 1e5 ? "rare" : ""}" data-klog="${esc(e.key)}" title="${e.gap && e.kills ? `${e.kills.toLocaleString()} ${kWord} while the plugin wasn't running (from RuneLite's Loot Tracker) · ` : ""}Show ${esc(e.name)} in Sources">
      <time datetime="${e.t.toISOString()}">${e.t.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</time>
      ${killIconHtml(src)}
      <span class="klog-name">${esc(titled(e.name))}${e.kc ? `<small>KC ${e.kc.toLocaleString()}</small>` : ""}${e.gap && e.kills ? `<small>${e.kills.toLocaleString()} ${kWord}</small>` : ""}</span>
      <span class="klog-items">${shown.length ? shown.map(([id, q]) => bankTile([id, q])).join("") : `<span class="muted small">${e.known ? "Nothing" : "Drops not saved"}</span>`}${more > 0 ? `<span class="klog-more">+${more}</span>` : ""}</span>
      <span class="kill-gp ${e.value >= 1e6 ? "big" : ""}" title="${e.value.toLocaleString()} GP ${e.gap ? "at today's GE price" : "when it dropped"}">${e.value ? compact(e.value) : "–"}</span>
    </button>`;
  }
  if (rows.length > n) html += `<button type="button" class="klog-load" data-klog-more>Show ${Math.min(KILL_LOG_PAGE, rows.length - n).toLocaleString()} more <small>of ${(rows.length - n).toLocaleString()}</small></button>`;
  list.innerHTML = html;
}

function renderKillList() {
  const list = $("kill-list");
  if (!list) return;
  list.classList.toggle("klog", state.killsView === "log");
  if (state.killsView === "log") return renderKillLog(list);
  const q = (state.killsQuery ?? "").trim().toLowerCase();
  const sort = state.killsSort ?? "kills";
  const hiddenView = !!state.killsShowHidden;
  const rows = killsInTabAll().filter((s) => killHidden(s.key) === hiddenView && (!q || s.name.toLowerCase().includes(q)));
  const by = { kills: (a, b) => b.kills - a.kills, value: (a, b) => b.value - a.value, recent: (a, b) => (b.last ?? 0) - (a.last ?? 0), name: (a, b) => a.name.localeCompare(b.name) }[sort];
  rows.sort((a, b) => by(a, b) || a.name.localeCompare(b.name));
  $("kill-count").textContent = rows.length.toLocaleString();
  const day = (d) => d?.toLocaleDateString(undefined, { month: "short", day: "numeric", year: d.getFullYear() === new Date().getFullYear() ? undefined : "numeric" });
  list.innerHTML = rows.length ? rows.map((s) => {
    const open = state.killsOpen === s.key;
    const drops = open ? [...s.drops].sort((a, b) => killPrice(b[0]) * b[1] - killPrice(a[0]) * a[1]) : [];
    return `<div class="cat ${open ? "open" : ""} ${hiddenView ? "none" : ""}" data-kill-key="${esc(s.key)}">
      <div class="kill-line">
      <button type="button" class="cat-row kill-row" data-kill="${esc(s.key)}" aria-expanded="${open}">
        ${killIconHtml(s)}
        <span class="cat-name">${esc(titled(s.name))}<small class="cat-kc">${state.killsTab === "all" ? `${killTypeName(killGroup(s))} · ` : ""}${s.last ? `last ${day(s.last)}` : ""}</small></span>
        <span class="kill-n"><b>${s.kills.toLocaleString()}</b> ${s.type === "NPC" || s.type === "PLAYER" || killGroup(s) === "BOSS" ? (s.kills === 1 ? "kill" : "kills") : "times"}</span>
        <span class="kill-gp ${s.value >= 1e6 ? "big" : ""}" title="${s.value.toLocaleString()} GP of drops at today's GE prices${s.kills && s.value ? ` · ≈ ${Math.round(s.value / s.kills).toLocaleString()} GP each` : ""}">${s.value ? compact(s.value) : "–"}${s.kills && s.value ? `<small>${compact(s.value / s.kills)} each</small>` : ""}</span>
      </button>
      <button type="button" class="kill-hide" data-kill-hide="${esc(s.key)}" title="${hiddenView ? "Show" : "Hide"} ${esc(s.name)}" aria-label="${hiddenView ? "Show" : "Hide"} ${esc(s.name)}">${hiddenView ? EYE : EYE_OFF}</button>
      </div>
      ${open ? `<div class="cat-parts">${s.kills ? `≈ ${compact(s.value / s.kills)} GP each` : ""}${s.first ? ` · first ${day(s.first)}` : ""} · ${s.drops.length} different drops</div>
        <div class="cat-items">${drops.length ? drops.map((d) => bankTile(d)).join("") : `<span class="muted small">No drops saved.</span>`}</div>` : ""}
    </div>`;
  }).join("") : `<p class="muted small kill-none">${hiddenView ? "Nothing hidden here." : "Nothing matches."}</p>`;
}

function revealKill(key) {
  const s = killSources().find((x) => x.key === key);
  if (!s || $("kills-card").hidden) return;
  if (state.killsTab !== "all" && state.killsTab !== killGroup(s)) state.killsTab = KILL_TYPES.some(([t]) => t === killGroup(s)) ? killGroup(s) : "OTHER";
  // Drop log open: stay in it, unfiltered (no search), scrolled to this monster's newest kill,
  // which flashes. Falls back to Sources when the log has none of its kills in the period, or it is hidden.
  const start = periodStart(state.period);
  if (state.killsView === "log" && !killHidden(key) && killLogEvents().some((ev) => ev.key === key && ev.t >= start)) {
    state.killsQuery = "";
    state.killLogN = null;
    renderKills();
    const list = $("kill-list"), sel = `[data-klog="${CSS.escape(key)}"]`;
    let row = list.querySelector(sel);
    while (!row && list.querySelector("[data-klog-more]")) { // older than the first page: show more until it's there
      state.killLogN = (state.killLogN ?? KILL_LOG_PAGE) + KILL_LOG_PAGE;
      renderKillList();
      row = list.querySelector(sel);
    }
    const pinned = (list.querySelector(".klog-head")?.offsetHeight ?? 0) + (list.querySelector(".klog-day")?.offsetHeight ?? 0);
    if (row) list.scrollTop += row.getBoundingClientRect().top - list.getBoundingClientRect().top - pinned;
    jumpTo($("kills-card"));
    if (row) flash(row);
    return;
  }
  state.killsView = "sources";
  state.killsQuery = "";
  state.killsShowHidden = killHidden(key);
  state.killsOpen = key;
  savePrefs();
  renderKills();
  const list = $("kill-list"), row = list.querySelector(`[data-kill-key="${CSS.escape(key)}"]`);
  if (row) list.scrollTop += row.getBoundingClientRect().top - list.getBoundingClientRect().top;
  jumpTo($("kills-card"));
  if (row) flash(row);
}

$("kills-card").addEventListener("click", (e) => {
  const tab = e.target.closest("[data-kill-tab]");
  if (tab) { state.killsTab = tab.dataset.killTab; state.killsOpen = null; state.killLogN = null; savePrefs(); renderKills(); return; }
  const view = e.target.closest("[data-kill-view]");
  if (view) {
    if (state.killsView === view.dataset.killView) return;
    state.killsView = view.dataset.killView; state.killsOpen = null; state.killLogN = null; state.killsShowHidden = false;
    savePrefs(); renderKills(); return;
  }
  if (e.target.closest("[data-klog-more]")) {
    const list = $("kill-list"), top = list.scrollTop;
    state.killLogN = (state.killLogN ?? KILL_LOG_PAGE) + KILL_LOG_PAGE;
    renderKillList(); list.scrollTop = top; return;
  }
  const logRow = e.target.closest("[data-klog]");
  if (logRow) {
    // That monster in Sources, opened; scrolls inside the list only (the page stays put)
    const key = logRow.dataset.klog, s = killSources().find((x) => x.key === key);
    if (!s) return;
    state.killsView = "sources"; state.killsQuery = ""; state.killsShowHidden = false; state.killsOpen = key;
    if (state.killsTab !== "all" && state.killsTab !== killGroup(s)) state.killsTab = KILL_TYPES.some(([t]) => t === killGroup(s)) ? killGroup(s) : "OTHER";
    savePrefs(); renderKills();
    const list = $("kill-list"), row = list.querySelector(`[data-kill-key="${CSS.escape(key)}"]`);
    if (row) { list.scrollTop += row.getBoundingClientRect().top - list.getBoundingClientRect().top; flash(row); }
    return;
  }
  const hide = e.target.closest("[data-kill-hide]");
  if (hide) {
    const key = hide.dataset.killHide, top = $("kill-list").scrollTop;
    state.killsHidden = killHidden(key) ? state.killsHidden.filter((k) => k !== key) : [...(state.killsHidden ?? []), key];
    if (state.killsOpen === key) state.killsOpen = null;
    savePrefs();
    renderKills();
    $("kill-list").scrollTop = top;
    state.activity = null; // the feed leaves hidden monsters out too
    renderFeed();
    return;
  }
  if (e.target.closest("[data-kill-hidden-view]")) {
    state.killsShowHidden = !state.killsShowHidden;
    state.killsOpen = null;
    renderKills();
    $("kill-list").scrollTop = 0;
    return;
  }
  const sort = e.target.closest("[data-kill-sort]");
  if (sort) { state.killsSort = sort.dataset.killSort; savePrefs(); setActive($("kill-sort"), sort); renderKillList(); $("kill-list").scrollTop = 0; return; }
  const row = e.target.closest("[data-kill]");
  if (row) {
    const list = $("kill-list"), top = list.scrollTop;
    state.killsOpen = state.killsOpen === row.dataset.kill ? null : row.dataset.kill;
    renderKillList();
    list.scrollTop = top;
  }
});
$("kills-card").addEventListener("input", (e) => {
  if (e.target.id !== "kill-search") return;
  state.killsQuery = e.target.value;
  state.killLogN = null;
  renderKillList();
  $("kill-list").scrollTop = 0;
});

// Kills between refreshes: the server saves the Loot Tracker totals on each Refresh (data\plugin\kills-history.jsonl).
// Returns history index -> [[key, gain], ...] for the refresh that picked them up.
function killGainsByRefresh(h) {
  const out = new Map(), kh = state.plugin?.killHistory ?? [];
  for (let j = 1; j < kh.length; j++) {
    const prev = kh[j - 1].k, cur = kh[j].k, t = +new Date(kh[j].t);
    let i = h.findIndex((s) => +s.time >= t - 5000);
    if (i === 0) continue;
    if (i < 0) i = h.length - 1;
    const gains = out.get(i) ?? new Map();
    for (const [key, n] of Object.entries(cur)) {
      const g = n - (prev[key] ?? 0);
      if (g > 0 && !killHidden(key) && !BOSS_NO_LOOT_FALLBACK.has(key.slice(key.indexOf("|") + 1))) gains.set(key, (gains.get(key) ?? 0) + g);
    }
    if (gains.size) out.set(i, gains);
  }
  for (const [i, g] of out) out.set(i, [...g].sort((a, b) => b[1] - a[1]));
  return out;
}
// The hiscores boss a Loot Tracker source counts toward ("NPC|Vorkath" -> Vorkath, "NPC|Corrupted Hunllef" ->
// The Corrupted Gauntlet), or null (not a hiscores boss, e.g. raid sub-bosses, which have their own raid entry)
function killBossName(key) {
  const name = key.slice(key.indexOf("|") + 1), bosses = state.history.at(-1)?.bosses ?? {};
  return name in bosses ? name : (CA_BOSS_ALIAS[name] ?? "") in bosses ? CA_BOSS_ALIAS[name] : null;
}
function killEvent(gains) {
  const total = gains.reduce((s, [, g]) => s + g, 0);
  const nameOf = (key) => titled(key.slice(key.indexOf("|") + 1));
  const src = new Map(killSources().map((s) => [s.key, s]));
  const chips = gains.map(([key, g]) => {
    const s = src.get(key), id = s?.best ?? s?.drops[0]?.[0];
    const npc = !key.startsWith("EVENT|") && (state.npcIcons ??= new Set(state.plugin?.npcIcons ?? [])).has(npcSlug(nameOf(key)));
    const pic = npc ? icon(`/icons/npc/${npcSlug(nameOf(key))}.png`) : id != null ? itemIcon(id) : null;
    return `<span class="mini-chip kill-chip" data-go="kill:${esc(key)}" role="button" tabindex="0" title="${esc(nameOf(key))}: +${g.toLocaleString()}${s ? ` · ${s.kills.toLocaleString()} total` : ""}">${pic ? `<img src="${pic}" alt="">` : ""}${esc(nameOf(key))} <b>+${g.toLocaleString()}</b></span>`;
  }).join("");
  // Named by what happened (user 2026-11-03: "Kills & Loots" with bird houses counted as kills read as nonsense):
  // monsters are kills; bird houses, nests, chests and caskets are opened; pickpockets apart
  const kinds = [["Kill", "Kills", (k) => k.startsWith("NPC|") || k.startsWith("PLAYER|")],
    ["Opened", "Opened", (k) => k.startsWith("EVENT|")], ["Pickpocket", "Pickpockets", (k) => k.startsWith("PICKPOCKET|")]];
  const title = kinds.map(([one, many, is]) => {
    const n = gains.filter(([k]) => is(k)).reduce((s, [, g]) => s + g, 0);
    return n ? `<em>+${n.toLocaleString()}</em> ${n === 1 ? one : many}` : "";
  }).filter(Boolean).join(" · ") || `<em>+${total.toLocaleString()}</em> ${total === 1 ? "Kill" : "Kills"}`;
  return {
    type: "kill", icon: skillIcon("Slayer"), tier: "#d9534f", go: `kill:${gains[0][0]}`,
    title, sub: "",
    extra: `<div class="kill-chips">${chips}</div>`,
  };
}

// ---------- recent activity ----------

const KC_MILESTONES = [50, 100, 250, 500, 1000, 2000, 5000];
// Start (ms) of the game day d is in: the 00:00 UTC reset before it
const dayKey = (d) => Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());

// Turn each pair of consecutive snapshots into a feed entry with events
function buildActivity() {
  const h = state.history;
  const entries = [];
  const caNew = caFinishedByRefresh();
  const killsAt = killGainsByRefresh(h);
  const bossLead = new Map(); // boss -> kills the plugin reported that the hiscores haven't counted yet
  for (let i = 1; i < h.length; i++) {
    const prev = h[i - 1], cur = h[i];
    const xp = cur.skills.Overall.xp - prev.skills.Overall.xp;
    const skills = [];
    const events = [];

    for (const name of Object.keys(cur.skills)) {
      if (name === "Overall") continue;
      const a = prev.skills[name], b = cur.skills[name];
      if (!a) continue;
      if (b.xp > a.xp) skills.push({ name, gain: b.xp - a.xp });
      if (b.level > a.level) {
        events.push({
          type: "level", gold: b.level >= 99, icon: skillIcon(name), go: `skill:${name}`,
          title: b.level >= 99 ? `<em>99 ${esc(name)}!</em> Skill Mastered` : `${esc(name)} Level <em>${b.level}</em>`,
          sub: b.level - a.level > 1 ? `+${b.level - a.level} levels · from ${a.level}` : `from ${a.level}`,
        });
      }
    }
    skills.sort((a, b) => b.gain - a.gain);

    // Total-XP milestones every 5M
    const step = 5_000_000;
    if (Math.floor(cur.skills.Overall.xp / step) > Math.floor(prev.skills.Overall.xp / step)) {
      events.push({
        type: "level", milestone: true, gold: true, icon: wikiIcon("Stats_icon.png"), go: "skills",
        title: `Passed <em>${compact(Math.floor(cur.skills.Overall.xp / step) * step)}</em> Total XP`,
        sub: `Total level ${cur.skills.Overall.level}`,
      });
    }

    // New collection log slots (only between two ranked snapshots)
    const clogGain = prev.clog ? cur.clog - prev.clog : 0;
    if (clogGain > 0) {
      events.push({
        type: "clog", icon: wikiIcon("Collection_log.png"), tier: "#e8b64c", go: "clog",
        title: `<em>+${clogGain}</em> Collection Log ${clogGain === 1 ? "Slot" : "Slots"}`,
        sub: `${cur.clog.toLocaleString()} logged`,
        extra: clogItemsHtml((state.clog?.sessions ?? []).filter((s) => +s.time === +cur.time), { compact: true }),
      });
    }

    // Collection log changes the hiscores slot count doesn't show: duplicates of owned items,
    // and new items the hiscores haven't counted yet (plugin counts)
    for (const d of state.clog?.dupes ?? []) {
      if (!d.at || +d.at !== +cur.time) continue;
      const n = d.to - d.from, vt = valueTier(d.id), gp = itemPrice(d.id);
      events.push({
        type: "clog", icon: itemIcon(d.id), tier: vt.color ?? "#e8b64c", valued: !!vt.color, go: `item:${d.id}`,
        title: d.from ? (vt.color ? `<em>+${n} ${esc(itemName(d.id))}</em>` : `<em>+${n}</em> ${esc(itemName(d.id))}`) : `New Collection Log Item: <em>${esc(itemName(d.id))}</em>`,
        sub: `${d.to.toLocaleString()} obtained${gp ? ` · ${compact(gp)} GE` : ""}`,
      });
    }

    // Combat achievement tasks newly finished, on the refresh that picked them up
    for (const t of caNew.get(+cur.time) ?? []) {
      events.push({
        type: "ca", icon: caIcon(t.tier), tier: CA_COLORS[t.tier], valued: CA_TIERS.indexOf(t.tier) >= 3,
        go: `ca:${t.name}`,
        title: `Combat Task: <em>${esc(titled(t.name))}</em>`,
        sub: `${t.tier} · ${t.pts} pt${t.pts > 1 ? "s" : ""} · ${esc(t.task)}`,
      });
    }

    // Boss kills: one card per boss, shown under both Bosses and Kills. Two sources: the official
    // hiscores (they only update once you log out or hop) and the plugin's Loot Tracker kills (right away). A kill
    // the plugin reported first is remembered ("lead") so the hiscores catching up later doesn't show it again.
    const kills = killsAt.get(i) ?? [];
    const pluginBoss = new Map(), otherKills = [];
    for (const [key, g] of kills) {
      const b = killBossName(key);
      if (b) pluginBoss.set(b, (pluginBoss.get(b) ?? 0) + g); else otherKills.push([key, g]);
    }
    const bossEvents = [];
    const names = new Set([...Object.keys(cur.bosses).filter((n) => cur.bosses[n] > (prev.bosses[n] ?? 0)), ...pluginBoss.keys()]);
    for (const name of names) {
      const hs = Math.max(0, (cur.bosses[name] ?? 0) - (prev.bosses[name] ?? 0));
      let ld = bossLead.get(name) ?? 0;
      const absorbed = Math.min(ld, hs);
      ld -= absorbed;
      const rest = hs - absorbed, pl = pluginBoss.get(name) ?? 0;
      const g = Math.max(rest, pl);
      ld += Math.max(0, pl - rest);
      bossLead.set(name, ld);
      if (g <= 0) continue;
      const total = (cur.bosses[name] ?? 0) + ld;
      const ms = KC_MILESTONES.filter((m) => total - g < m && total >= m).pop();
      bossEvents.push({
        type: "boss", also: ["kill"], gold: !!ms, gain: g, bossName: name, go: `boss:${name}`,
        title: `<em>+${g.toLocaleString()}</em> ${esc(titled(name))} ${g === 1 ? "Kill" : "Kills"}`,
        sub: ms ? `${ms.toLocaleString()} KC milestone · ${total.toLocaleString()} total` : `${total.toLocaleString()} KC`,
      });
    }
    bossEvents.sort((a, b) => b.gain - a.gain);
    events.push(...bossEvents);

    for (const { key, color } of CLUE_TIERS) {
      const g = (cur.clues[key] ?? 0) - (prev.clues[key] ?? 0);
      if (g <= 0) continue;
      const label = key[0].toUpperCase() + key.slice(1);
      events.push({
        type: "clue", tier: color, icon: `${gameIcon("cluescrolls" + key)}`, go: `clue:${key}`,
        title: `<em>+${g}</em> ${label} ${g === 1 ? "Clue" : "Clues"}`,
        sub: `${(cur.clues[key] ?? 0).toLocaleString()} completed`,
      });
    }

    if (otherKills.length) events.push(killEvent(otherKills)); // bosses have their own card (above)
    if (xp > 0 || events.length) entries.push({ time: cur.time, from: prev.time, xp, skills, events });
  }
  return entries.reverse();
}

// Lists of entries (feed, drop log) are headed by your own calendar day, so each heading holds what you did that date
const localDayKey = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
function localDayName(d, short = false) {
  const now = new Date(), diff = Math.round((localDayKey(now) - localDayKey(d)) / 864e5);
  if (diff === 0) return "Today";
  if (diff === 1) return "Yesterday";
  const year = d.getFullYear() === now.getFullYear() ? undefined : "numeric";
  if (short) return d.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric", year });
  if (diff < 7) return d.toLocaleDateString(undefined, { weekday: "long" });
  return d.toLocaleDateString(undefined, { month: "long", day: "numeric", year });
}

function renderFeed() {
  const all = (state.activity ??= buildActivity()); // built once per data load
  const f = state.feedFilter;
  const levels = all.reduce((s, e) => s + e.events.filter((v) => v.type === "level" && !v.milestone).length, 0);
  $("activity-sub").textContent = all.length
    ? `${all.length} session${all.length > 1 ? "s" : ""} · ${levels} level-up${levels === 1 ? "" : "s"}`
    : "Your progress between updates";

  const entries = all
    .map((e) => ({ ...e, events: f === "all" ? e.events : e.events.filter((v) => v.type === f || v.also?.includes(f)) }))
    .filter((e) => f === "all" || e.events.length)
    .slice(0, 60);

  if (!entries.length) {
    $("feed").innerHTML = `<div class="feed-empty muted small">
      <img src="${wikiIcon("Stats_icon.png")}" alt=""><p>${all.length ? "Nothing here yet for this filter." : "Play a bit, then press <b>Update</b>.<br>Level-ups, boss kills and clues will show up here."}</p></div>`;
    return;
  }

  let html = "", lastDay = null;
  entries.forEach((e, i) => {
    const dk = localDayKey(e.time);
    if (dk !== lastDay) { html += `<div class="feed-day">${localDayName(e.time)}</div>`; lastDay = dk; }
    const time = fmtDate(e.time, { hour: "numeric", minute: "2-digit" });
    const longGap = e.time - e.from > 36 * 3600e3;
    // The XP badge (and skill chips) only in "All Activity": a filtered view isn't about XP
    // All skills are rendered; past the first 4 they stay hidden until "+N more" is clicked
    const chips = f === "all" ? e.skills.map((s, si) =>
      `<span class="mini-chip ${si >= 4 ? "extra" : ""}" data-skill="${esc(s.name)}" title="${esc(s.name)}: +${s.gain.toLocaleString()} XP"><img src="${skillIcon(s.name)}" alt="">+${compact(s.gain)}</span>`).join("")
      + (e.skills.length > 4 ? `<button type="button" class="mini-chip more-btn" data-more="${e.skills.length - 4}" aria-expanded="false">+${e.skills.length - 4} more</button>` : "") : "";
    const evs = e.events.map((v) => `
      <div class="event ev-${v.type} ${v.gold ? "gold" : ""} ${v.milestone ? "milestone" : ""} ${v.valued ? "valued" : ""}" ${v.tier ? `style="--tier:${v.tier}"` : ""}
        ${v.go ? `data-go="${esc(v.go)}" role="button" tabindex="0" title="Go to ${esc(feedGoLabel(v.go.split(":")[0]) ?? "it")}"` : ""}>
        <div class="event-icon" ${v.bossName ? bossIconHtml(v.bossName) : `><img src="${v.icon}" alt="" loading="lazy">`}</div>
        <div><div class="event-title">${v.title}</div>${v.sub ? `<div class="event-sub">${v.sub}</div>` : ""}${v.extra ? `<div class="event-extra">${v.extra}</div>` : ""}</div>
      </div>`).join("");
    html += `<div class="entry ${e.events.some((v) => v.gold) ? "has-99" : ""}" style="animation-delay:${Math.min(i, 10) * 40}ms">
      <div class="entry-head">
        <span class="entry-time" title="Changes since ${e.from.toLocaleString()}">${time}${longGap ? ` · since ${e.from.toLocaleDateString(undefined, { month: "short", day: "numeric" })}` : ""}</span>
        ${e.xp > 0 && f === "all" ? `<span class="xp-badge xp${sessionLevel(e.xp)}" title="${e.xp.toLocaleString()} XP this session">+${compact(e.xp)} XP</span>` : ""}
      </div>
      ${chips ? `<div class="entry-skills">${chips}</div>` : ""}
      ${evs ? `<div class="events">${evs}</div>` : ""}
    </div>`;
  });
  $("feed").innerHTML = html;
}

// XP-per-session ranges for the "+X XP" bubbles in the activity log (xp1..xp6),
// tuned to this player's typical sessions
const SESSION_STEPS = [0, 25_000, 60_000, 150_000, 300_000, 500_000];
const sessionLevel = (xp) => SESSION_STEPS.reduce((lvl, min, i) => (xp >= min ? i + 1 : lvl), 1);

function renderHeatmap() {
  const h = state.history;
  const daily = new Map();
  for (let i = 1; i < h.length; i++) {
    const g = h[i].skills.Overall.xp - h[i - 1].skills.Overall.xp;
    if (g > 0) daily.set(dayKey(h[i].time), (daily.get(dayKey(h[i].time)) || 0) + g);
  }

  const HEAT_WEEKS = 16; // fills the wider Recent activity column
  const today = new Date(dayKey(new Date()));
  const start = new Date(today);
  start.setUTCDate(start.getUTCDate() - 7 * (HEAT_WEEKS - 1) - today.getUTCDay()); // one column per week, weeks start Sunday
  const max = Math.max(1, ...daily.values());
  const cells = [];
  for (let d = new Date(start); cells.length < HEAT_WEEKS * 7; d.setUTCDate(d.getUTCDate() + 1)) {
    const key = d.getTime(), v = daily.get(key) || 0;
    const lvl = v <= 0 ? 0 : Math.min(4, 1 + Math.floor((v / max) * 3.999));
    const cls = key > today.getTime() ? "future" : key === today.getTime() ? "today" : "";
    cells.push(`<div class="cell h${lvl} ${cls}" data-tip="${esc(fmtDate(d, { ...GAME_DAY, weekday: "short", month: "short", day: "numeric" }))}" data-xp="${v}"></div>`);
  }
  $("heatmap").innerHTML = cells.join("");

  // Streak = consecutive days with XP ending today or yesterday
  let streak = 0;
  const cur = new Date(today);
  if (!daily.has(cur.getTime())) cur.setUTCDate(cur.getUTCDate() - 1);
  while (daily.has(cur.getTime())) { streak++; cur.setUTCDate(cur.getUTCDate() - 1); }
  const monthStart = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1);
  const activeMonth = [...daily.keys()].filter((k) => k >= monthStart).length;
  const best = daily.size ? Math.max(...daily.values()) : 0;

  $("heat-stats").innerHTML = `
    <div class="heat-stat"><b>${streak}</b><span>day streak</span></div>
    <div class="heat-stat"><b>${activeMonth}</b><span>active days this month</span></div>
    <div class="heat-stat"><b>${best ? compact(best) : "–"}</b><span>best day XP</span></div>`;
}

// Shared floating tooltip, positioned above an element
function placeTip(el, html) {
  const tip = $("tip");
  if (!el) { tip.hidden = true; return; }
  tip.innerHTML = html;
  const r = el.getBoundingClientRect();
  tip.style.left = r.left + r.width / 2 + "px";
  tip.style.top = r.top + "px";
  tip.hidden = false;
}

function showTip(e) {
  const cell = e.target.closest(".cell[data-tip]");
  const xp = Number(cell?.dataset.xp);
  placeTip(cell, `<b>${xp > 0 ? "+" + xp.toLocaleString() + " XP" : "No XP"}</b> · ${cell?.dataset.tip}`);
}

function showSkillTip(e) {
  const el = e.target.closest(".skill[data-skill]");
  if (!el) return placeTip(null);
  const d = el.dataset;
  const gain = Number(d.gain), rank = Number(d.rank);
  placeTip(el, `
    <div class="tip-title">${esc(d.skill)}</div>
    <div class="tip-row"><span>XP</span><b>${Number(d.xp).toLocaleString()}</b></div>
    <div class="tip-row"><span>To ${d.next}</span><b>${Number(d.tonext).toLocaleString()}</b></div>
    <div class="tip-bar"><i style="width:${(d.pct * 100).toFixed(1)}%"></i></div>
    <div class="tip-row"><span>Rank</span><b>${rank > 0 ? "#" + rank.toLocaleString() : "–"}</b></div>
    ${gain > 0 ? `<div class="tip-row"><span>Gained</span><b class="pos">+${gain.toLocaleString()}</b></div>` : ""}`);
}

// ---------- chart ----------

// Bars per game day / week / month (from the reset, UTC) or per hour
function bucketKey(d, unit) {
  const y = d.getUTCFullYear(), m = d.getUTCMonth(), day = d.getUTCDate();
  if (unit === "hour") return new Date(Date.UTC(y, m, day, d.getUTCHours()));
  if (unit === "week") return new Date(Date.UTC(y, m, day - d.getUTCDay())); // weeks start Sunday's reset
  if (unit === "month") return new Date(Date.UTC(y, m, 1));
  return new Date(Date.UTC(y, m, day));
}

function nextBucket(d, unit) {
  const n = new Date(d);
  if (unit === "hour") n.setUTCHours(n.getUTCHours() + 1);
  else if (unit === "week") n.setUTCDate(n.getUTCDate() + 7);
  else if (unit === "month") n.setUTCMonth(n.getUTCMonth() + 1);
  else n.setUTCDate(n.getUTCDate() + 1);
  return n;
}

// ---------- chart series: what the chart compares ----------

// One color per selection, kept while it stays selected (removing one never repaints the others)
const SERIES_COLORS = ["#e8b64c", "#38bdf8", "#f472b6", "#4ade80", "#a78bfa", "#fb923c"];
const MAX_SERIES = SERIES_COLORS.length;
const isSel = (kind, name) => state.series.some((s) => s.kind === kind && s.name === name);
// XP and kill/clue counts are different scales, so they never share the chart
const scaleOf = (kind) => (kind === "skill" ? "xp" : "count");
const alpha = (hex, a) => hex + Math.round(a * 255).toString(16).padStart(2, "0");

function seriesInfo(s) {
  if (s.kind === "boss") return { label: s.name, unit: "kills", value: (snap) => snap.bosses[s.name] ?? 0 };
  if (s.kind === "clue") return { label: `${s.name[0].toUpperCase() + s.name.slice(1)} clues`, unit: "clues", value: (snap) => snap.clues[s.name] ?? 0 };
  if (s.kind === "clog") return { label: "Collection Log", unit: "slots", value: clogOf };
  if (s.kind === "item") return { label: itemName(s.name), unit: "obtained", none: "None obtained", value: (snap) => (state.clog ? itemCountAt(s.name, snap.time) : 0) };
  return { label: s.name, unit: "XP", value: (snap) => snap.skills[s.name]?.xp ?? 0 };
}

// The selected series, or Total XP when nothing is selected
function chartSeries() {
  if (!state.series.length) {
    return [{ kind: "skill", name: "Overall", color: SERIES_COLORS[0], label: "Total", unit: "XP", value: (snap) => snap.skills.Overall.xp }];
  }
  return state.series.map((s) => ({ ...s, ...seriesInfo(s) }));
}

function chartTitle(list) {
  if (list.length === 1) {
    const s = list[0];
    return titled(s.kind === "skill" ? `${s.label} XP` : s.kind === "boss" ? `${s.label} kills` : s.kind === "item" ? `${s.label} obtained` : s.label);
  }
  const units = new Set(list.map((s) => s.unit));
  const unit = units.size > 1 ? (list.some((s) => s.kind === "item" || s.kind === "clog") ? "kills, clues & items" : "kills & clues") : list[0].unit;
  const names = list.length <= 3 ? list.map((s) => s.label).join(" vs ") : `${list.length} compared`;
  return titleCase(`${names} · ${unit}`);
}

// The skill shown in the detail card: the most recently selected skill
function syncSelectedSkill() {
  const skills = state.series.filter((s) => s.kind === "skill");
  state.selected = skills.length ? skills.at(-1).name : "Overall";
  // The detail card follows the last selected skill or item
  const last = state.series.filter((s) => s.kind === "skill" || s.kind === "item").at(-1);
  state.detailItem = last?.kind === "item" ? last.name : null;
  restoreChartMode();
}

// Nothing selected any more: back to the chart mode from before a boss/clue/item switched it to "Per Day"
function restoreChartMode() {
  if (state.series.length || !state.modeBeforeSel) return;
  state.chartMode = state.modeBeforeSel;
  state.modeBeforeSel = null;
  state.pick = null;
  setActive($("chart-mode"), $("chart-mode").querySelector(`[data-mode="${state.chartMode}"]`));
}

// Click a skill, boss or clue tier: add it to the chart, or remove it if it's already there
function toggleSeries(kind, name) {
  const i = state.series.findIndex((s) => s.kind === kind && s.name === name);
  if (i >= 0) {
    state.series.splice(i, 1);
  } else {
    if (state.series.length && scaleOf(state.series[0].kind) !== scaleOf(kind)) {
      state.series = [];
      state.pick = null;
      toast(kind === "skill" ? "Chart switched to XP" : "Chart switched to kills & clues");
    }
    if (state.series.length >= MAX_SERIES) {
      toast(`You can compare up to ${MAX_SERIES} at once`, "error");
      return;
    }
    const used = new Set(state.series.map((s) => s.color));
    state.series.push({ kind, name, color: SERIES_COLORS.find((c) => !used.has(c)) });
    // Kills and clues are easiest to read per day (the old mode comes back once nothing is selected)
    if (kind !== "skill" && state.chartMode !== "daily") {
      state.modeBeforeSel ??= state.chartMode;
      state.chartMode = "daily";
      setActive($("chart-mode"), $("chart-mode").querySelector('[data-mode="daily"]'));
    }
  }
  syncSelectedSkill();
  render();
}

function dailySeries(snaps, value, start) {
  const from = snaps[0].time > start ? snaps[0].time : start;
  const spanDays = (Date.now() - from) / 86400e3;
  const unit = /^(day|[23]d)$/.test(state.period) ? "hour" : state.period === "3m" || state.period === "6m" ? "week" : spanDays > 120 ? "month" : "day";
  const sums = new Map();
  for (let i = 1; i < snaps.length; i++) {
    const g = value(snaps[i]) - value(snaps[i - 1]);
    const k = +bucketKey(snaps[i].time, unit);
    sums.set(k, (sums.get(k) || 0) + Math.max(0, g));
  }
  const out = [];
  for (let b = bucketKey(from, unit); b <= new Date(); b = nextBucket(b, unit)) {
    out.push({ x: b, y: sums.get(+b) || 0 });
  }
  return { points: out, unit };
}

// Space between the comparison legend and the plot (Chart.js has no option for it)
const LEGEND_GAP = { id: "legendGap", beforeInit(chart) {
  const legend = chart.legend;
  if (!legend) return;
  const fit = legend.fit;
  legend.fit = function () { fit.call(this); this.height += 18; };
} };

function renderChart(c) {
  const list = chartSeries();
  const multi = list.length > 1;
  const snaps = c.h.slice(c.bi);
  const mode = state.chartMode;
  $("chart-title").textContent = chartTitle(list);
  renderSelection();

  const empty = snaps.length < 2;
  $("chart-empty").hidden = !empty;
  $("xp-chart").parentElement.hidden = empty;
  if (state.chart) { state.chart.destroy(); state.chart = null; }
  state.bars = null;
  if (empty || !window.Chart || mode !== "daily") renderInsight();
  if (empty) { $("chart-sub").textContent = ""; return; }
  if (!window.Chart) {
    // vendor\chart.umd.min.js didn't load: almost always a server started before it was added
    $("chart-empty").hidden = false;
    $("xp-chart").parentElement.hidden = true;
    $("chart-empty").innerHTML = `<p>The chart couldn't load.</p><p class="muted small">Close the server window and run <strong>start.bat</strong> again, then reload.</p>`;
    return;
  }

  const gold = "#e8b64c", muted = "#7d7b74", grid = "rgba(255,255,255,.06)";
  const gains = list.map((s) => Math.max(0, s.value(snaps.at(-1)) - s.value(snaps[0])));
  $("chart-sub").textContent = multi
    ? list.map((s, i) => `${s.label} +${compact(gains[i])}`).join(" · ")
    : gains[0] > 0 ? `+${gains[0].toLocaleString()} ${list[0].unit} in this view` : list[0].none ? `${list[0].none} in this view` : `No ${list[0].unit} gained in this view`;
  Chart.defaults.font.size = 13; // matches the dashboard text (everything a little bigger)
  // Compact labels (109.8M) unless the steps are too small to tell apart; then exact numbers
  const yTicks = { color: muted, precision: 0, callback: (v, i, ticks) => {
    const step = ticks.length > 1 ? Math.abs(ticks[1].value - ticks[0].value) : v;
    return step > 0 && step < Math.abs(v) / 500 ? v.toLocaleString() : compact(v);
  } };
  const legend = { display: multi, position: "top", align: "start",
    labels: { color: "#b9b6ab", usePointStyle: true, pointStyle: "rectRounded", boxWidth: 10, boxHeight: 10, padding: 14, font: { size: 13, weight: "600" },
      // Swatches use each selection's own color, not the faded bar colors
      generateLabels: (chart) => chart.data.datasets.map((d, i) => ({
        text: d.label, fillStyle: list[i].color, strokeStyle: list[i].color, lineWidth: 0, pointStyle: "rectRounded",
        fontColor: "#b9b6ab", datasetIndex: i, hidden: !chart.isDatasetVisible(i),
      })) } };
  const tooltip = {
    backgroundColor: "#202634", borderColor: "rgba(255,255,255,.13)", borderWidth: 1,
    titleColor: "#f3f1ea", bodyColor: "#b9b6ab", padding: 10, cornerRadius: 10,
    displayColors: multi, boxPadding: 4, usePointStyle: true,
  };

  if (mode === "total") {
    const span = snaps.at(-1).time - snaps[0].time;
    const fmtOpts = span < 2 * 86400e3 ? { hour: "numeric", minute: "2-digit" } : { month: "short", day: "numeric" };
    state.chart = new Chart($("xp-chart"), {
      type: "line",
      plugins: [LEGEND_GAP],
      data: {
        datasets: list.map((s) => ({
          label: s.label,
          data: snaps.map((snap) => ({ x: +snap.time, y: s.value(snap) })),
          borderColor: s.color, borderWidth: multi ? 2 : 2.5, tension: s.unit === "XP" ? 0.25 : 0,
          pointRadius: snaps.length > 40 ? 0 : 4, pointHoverRadius: 7,
          pointBackgroundColor: s.color, pointBorderColor: "#12161e", pointBorderWidth: 2,
          fill: !multi,
          backgroundColor: (cx) => {
            const { ctx: g, chartArea: a } = cx.chart;
            if (!a) return s.color;
            const grad = g.createLinearGradient(0, a.top, 0, a.bottom);
            grad.addColorStop(0, alpha(s.color, 0.35));
            grad.addColorStop(1, alpha(s.color, 0));
            return grad;
          },
        })),
      },
      options: {
        maintainAspectRatio: false,
        layout: { padding: { left: 4, right: 10, top: 10 } },
        interaction: { mode: multi ? "index" : "nearest", axis: "x", intersect: false },
        plugins: {
          legend,
          tooltip: { ...tooltip, callbacks: {
            title: (it) => new Date(it[0].parsed.x).toLocaleString(),
            label: (it) => {
              const s = list[it.datasetIndex];
              const i = it.dataIndex, prev = i > 0 ? it.dataset.data[i - 1].y : null;
              const d = prev != null && it.parsed.y > prev ? `  (+${(it.parsed.y - prev).toLocaleString()})` : "";
              return `${multi ? s.label + ": " : ""}${it.parsed.y.toLocaleString()} ${s.unit}${d}`;
            },
          } },
        },
        scales: {
          x: { type: "linear", min: +snaps[0].time, max: +snaps.at(-1).time,
               ticks: { color: muted, maxTicksLimit: 7, callback: (v) => fmtDate(new Date(v), fmtOpts) },
               grid: { display: false }, border: { color: grid } },
          y: { ticks: yTicks, grid: { color: grid }, border: { display: false } },
        },
      },
    });
  } else {
    const per = list.map((s) => dailySeries(snaps, s.value, c.start).points);
    const unit = dailySeries(snaps, list[0].value, c.start).unit;
    const points = per[0].map((p, i) => ({ x: p.x, y: per.reduce((t, pts) => t + pts[i].y, 0) }));
    state.bars = { points, unit, per, list };
    // Forget a clicked bar that is no longer in this view (other period / bucket size)
    if (state.pick && (state.pick.unit !== unit || !points.some((p) => +p.x === state.pick.key))) state.pick = null;
    const lbl = unit === "hour" ? (state.period === "day" ? { hour: "numeric" } : { weekday: "short", hour: "numeric" }) : unit === "month" ? { ...GAME_DAY, month: "short", year: "2-digit" } : { ...GAME_DAY, month: "short", day: "numeric" };
    $("chart-sub").textContent += " · click a bar for details";
    state.chart = new Chart($("xp-chart"), {
      type: "bar",
      plugins: [LEGEND_GAP],
      data: {
        labels: points.map((p) => fmtDate(p.x, lbl)),
        datasets: list.map((s, si) => ({
          label: s.label,
          data: per[si].map((p) => p.y),
          backgroundColor: barColors(si),
          hoverBackgroundColor: multi ? s.color : gold,
          // stacked segments get a thin gap so each selection reads as its own block
          borderColor: "#12161e", borderWidth: multi ? { top: 2 } : 0,
          borderRadius: multi ? 3 : 4, borderSkipped: multi ? false : "start",
          maxBarThickness: 28, minBarLength: multi ? 0 : 2, stack: "all",
        })),
      },
      options: {
        maintainAspectRatio: false,
        layout: { padding: { top: 10 } },
        // Clicking anywhere in a bar's column picks it (thin bars are hard to hit)
        interaction: { mode: "index", intersect: false },
        onHover: (e, els) => { e.native.target.style.cursor = els.length ? "pointer" : "default"; },
        onClick: (e, els) => {
          if (!els.length) return;
          const key = +points[els[0].index].x;
          pickBar(state.pick?.key === key ? null : key);
        },
        plugins: {
          legend,
          tooltip: { ...tooltip,
            filter: (it) => !multi || it.parsed.y > 0,
            callbacks: {
              title: (it) => (unit === "week" ? "Week of " : "") + points[it[0].dataIndex].x.toLocaleString(undefined, unit === "hour"
                ? { weekday: "short", hour: "numeric" } : unit === "month" ? { ...GAME_DAY, month: "long", year: "numeric" } : { ...GAME_DAY, weekday: "short", month: "short", day: "numeric" }),
              label: (it) => {
                const s = list[it.datasetIndex];
                if (!multi) return it.parsed.y > 0 ? `+${it.parsed.y.toLocaleString()} ${s.unit}` : s.none ?? `No ${s.unit}`;
                return `${s.label}: +${it.parsed.y.toLocaleString()} ${s.unit}`;
              },
              footer: (it) => (multi && !it.length ? "Nothing selected here" : ""),
            } },
        },
        scales: {
          x: { stacked: true, ticks: { color: muted, maxTicksLimit: 12, autoSkip: true, maxRotation: 0 }, grid: { display: false }, border: { color: grid } },
          y: { stacked: true, beginAtZero: true, ticks: yTicks, grid: { color: grid }, border: { display: false } },
        },
      },
    });
    renderInsight();
  }
}

// Bar colors. One series: green, gold for the clicked bar. Several: each series' own color,
// the clicked column at full strength and the rest faded.
function barColors(si = 0) {
  const { per, list } = state.bars;
  const pick = state.pick?.key;
  if (list.length === 1) {
    return per[0].map((p) => {
      if (+p.x === pick) return "#e8b64c";
      if (p.y <= 0) return "rgba(255,255,255,.06)";
      return pick ? "rgba(74,222,128,.45)" : "#4ade80";
    });
  }
  const color = list[si].color;
  return per[si].map((p) => (pick && +p.x !== pick ? alpha(color, 0.3) : color));
}

function pickBar(key) {
  state.pick = key == null ? null : { key, unit: state.bars.unit };
  renderSelection();
  if (state.chart) {
    state.chart.data.datasets.forEach((d, i) => { d.backgroundColor = barColors(i); });
    state.chart.update("none");
  }
  renderInsight();
}

// ---------- bar insights ----------

// Everything that changed in one chart bucket (hour / day / month). Uses the same
// rule as the bars: a refresh's gains count toward the bucket the refresh falls in,
// measured against the refresh before it.
function bucketInsight(key, unit) {
  const h = state.history;
  const end = +nextBucket(new Date(key), unit);
  let first = -1, last = -1;
  for (let i = 1; i < h.length; i++) {
    const t = +h[i].time;
    if (t >= key && t < end) { if (first < 0) first = i; last = i; }
  }
  if (first < 0) return null;
  const a = h[first - 1], b = h[last];

  const skills = [];
  for (const name of Object.keys(b.skills)) {
    if (name === "Overall" || !a.skills[name]) continue;
    const s0 = a.skills[name], s1 = b.skills[name];
    const gain = s1.xp - s0.xp;
    if (gain > 0) skills.push({ name, gain, from: s0.level, to: s1.level, xp: s1.xp });
  }
  skills.sort((x, y) => y.gain - x.gain);

  const bosses = Object.keys(b.bosses)
    .map((name) => ({ name, gain: b.bosses[name] - (a.bosses[name] ?? 0), total: b.bosses[name] }))
    .filter((x) => x.gain > 0)
    .sort((x, y) => y.gain - x.gain);

  const clues = CLUE_TIERS
    .map(({ key: k, color }) => ({ key: k, color, gain: (b.clues[k] ?? 0) - (a.clues[k] ?? 0), total: b.clues[k] ?? 0 }))
    .filter((x) => x.gain > 0);

  const o0 = a.skills.Overall, o1 = b.skills.Overall;
  return {
    sessions: last - first + 1, from: a.time, firstAt: h[first].time, lastAt: b.time,
    xp: pos(o1.xp - o0.xp), levels: pos(o1.level - o0.level), totalLevel: o1.level,
    rankFrom: o0.rank, rankTo: o1.rank,
    skills, bosses, clues,
    kills: bosses.reduce((s, x) => s + x.gain, 0),
    clog: a.clog ? pos(b.clog - a.clog) : 0, clogTotal: b.clog,
  };
}

function renderInsight() {
  const box = $("bar-insight");
  const pick = state.pick;
  if (!pick || state.chartMode !== "daily" || !state.bars) { box.hidden = true; return; }
  const { key, unit } = pick;
  const d = new Date(key);
  const title = unit === "hour"
    ? `${d.toLocaleDateString(undefined, { weekday: "long", month: "short", day: "numeric" })} · ${d.toLocaleTimeString(undefined, { hour: "numeric" })}–${nextBucket(d, unit).toLocaleTimeString(undefined, { hour: "numeric" })}`
    : unit === "month" ? d.toLocaleDateString(undefined, { ...GAME_DAY, month: "long", year: "numeric" })
    : unit === "week" ? `Week of ${d.toLocaleDateString(undefined, { ...GAME_DAY, month: "long", day: "numeric" })} – ${new Date(+nextBucket(d, unit) - 1).toLocaleDateString(undefined, { ...GAME_DAY, month: "long", day: "numeric", year: "numeric" })}`
    : d.toLocaleDateString(undefined, { ...GAME_DAY, weekday: "long", month: "long", day: "numeric", year: "numeric" });
  const ins = bucketInsight(key, unit);

  // Previous / next bars that have any activity
  const active = state.bars.points.filter((p) => p.y > 0 || (ins && +p.x === key)).map((p) => +p.x);
  const prev = [...active].reverse().find((k) => k < key);
  const next = active.find((k) => k > key);
  const nav = `<div class="ins-nav">
      <button type="button" data-go="${prev ?? ""}" ${prev == null ? "disabled" : ""} title="Previous active ${unit}">‹</button>
      <button type="button" data-go="${next ?? ""}" ${next == null ? "disabled" : ""} title="Next active ${unit}">›</button>
      <button type="button" data-close title="Close">✕</button>
    </div>`;
  const head = (sub) => `<div class="card-head ins-head">
      <div><h3>${esc(title)}</h3><p class="muted small">${sub}</p></div>${nav}</div>`;

  box.hidden = false;
  if (!ins) {
    box.innerHTML = head("No updates in this " + unit) +
      `<p class="muted small ins-empty">Nothing was recorded here. Gains show up in the ${unit} you press <b>Update</b>.</p>`;
    return;
  }

  const t = (x) => x.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  const sameDay = dayKey(ins.firstAt) === dayKey(ins.lastAt);
  const span = unit === "month" || !sameDay
    ? `${ins.firstAt.toLocaleDateString(undefined, { month: "short", day: "numeric" })} – ${ins.lastAt.toLocaleDateString(undefined, { month: "short", day: "numeric" })}`
    : ins.sessions > 1 ? `${t(ins.firstAt)} – ${t(ins.lastAt)}` : t(ins.lastAt);
  const longGap = ins.firstAt - ins.from > 36 * 3600e3
    ? ` · includes gains since ${ins.from.toLocaleDateString(undefined, { month: "short", day: "numeric" })}` : "";
  const sub = `${ins.sessions} update${ins.sessions > 1 ? "s" : ""} · ${span}${longGap}`;

  const rankMove = ins.rankFrom > 0 && ins.rankTo > 0 && ins.rankTo < ins.rankFrom
    ? `▲ ${(ins.rankFrom - ins.rankTo).toLocaleString()} ranks` : `Total level ${ins.totalLevel.toLocaleString()}`;
  const stats = [
    ["XP Gained", ins.xp ? "+" + ins.xp.toLocaleString() : "–", rankMove],
    ["Levels Gained", ins.levels ? "+" + ins.levels : "–", `${ins.skills.filter((s) => s.to > s.from).length} skills`],
    ["Boss Kills", ins.kills ? "+" + ins.kills.toLocaleString() : "–", `${ins.bosses.length} boss${ins.bosses.length === 1 ? "" : "es"}`],
    ["Clues", ins.clues.length ? "+" + ins.clues.reduce((s, x) => s + x.gain, 0) : "–", ins.clues.map((c) => c.key).join(", ") || "none"],
    ["Collection Log", ins.clog ? "+" + ins.clog : "–", ins.clogTotal ? `${ins.clogTotal.toLocaleString()} logged` : "not listed yet"],
  ].map(([k, v, s]) => `<div class="ins-stat"><span>${k}</span><b class="${v !== "–" ? "pos" : ""}">${v}</b><small>${esc(s)}</small></div>`).join("");

  const maxGain = ins.skills[0]?.gain || 1;
  const skillsHtml = ins.skills.length
    ? ins.skills.map((s) => `<div class="gain-row ${isSel("skill", s.name) ? "sel" : ""}" data-skill="${esc(s.name)}" title="${s.xp.toLocaleString()} XP total">
        <img src="${skillIcon(s.name)}" alt="">
        <div><div class="name">${esc(s.name)}${s.to > s.from ? ` <span class="ins-lvl">${s.from} → <b>${s.to}</b></span>` : ""}</div>
          <div class="bar-track"><div class="bar-fill green" style="width:${(s.gain / maxGain * 100).toFixed(1)}%"></div></div></div>
        <b>+${compact(s.gain)}</b></div>`).join("")
    : `<p class="muted small">No XP gained.</p>`;

  const bossHtml = ins.bosses.length
    ? ins.bosses.map((x) => `<div class="ins-row ${isSel("boss", x.name) ? "sel" : ""}">
        <div class="boss-icon" ${bossIconHtml(x.name)}</div>
        <div><div class="name">${esc(x.name)}</div><div class="muted small">${x.total.toLocaleString()} KC</div></div>
        <b>+${x.gain.toLocaleString()}</b></div>`).join("")
    : `<p class="muted small">No boss kills.</p>`;

  const clueHtml = ins.clues.length
    ? ins.clues.map((x) => `<div class="ins-row ${isSel("clue", x.key) ? "sel" : ""}">
        <div class="boss-icon"><img src="${gameIcon("cluescrolls" + x.key)}" alt=""></div>
        <div><div class="name" style="color:${x.color}">${x.key[0].toUpperCase() + x.key.slice(1)}</div><div class="muted small">${x.total.toLocaleString()} completed</div></div>
        <b>+${x.gain}</b></div>`).join("")
    : `<p class="muted small">No clues.</p>`;

  box.innerHTML = head(sub) + `
    <div class="ins-stats">${stats}</div>
    <div class="ins-cols">
      <div><h4>Skills Trained</h4>${skillsHtml}</div>
      <div><h4>Boss Kills</h4>${bossHtml}<h4 class="ins-gap">Clue Scrolls</h4>${clueHtml}
        ${ins.clog ? `<h4 class="ins-gap">Collection Log Items</h4>${clogItemsHtml(clogSessionsBetween(new Date(key), nextBucket(new Date(key), unit))) || `<p class="muted small">+${ins.clog} new slots</p>`}` : ""}</div>
    </div>`;
}

$("bar-insight").addEventListener("click", (e) => {
  if (e.target.closest("[data-close]")) return pickBar(null);
  const go = e.target.closest("[data-go]");
  if (go && go.dataset.go) return pickBar(Number(go.dataset.go));
  const sk = e.target.closest("[data-skill]");
  if (sk) selectSkill(sk.dataset.skill);
});

// ---------- interactions ----------

function moveIndicator() {
  const active = document.querySelector("#periods button.active");
  const ind = document.querySelector(".seg-indicator");
  if (!active || !ind) return;
  ind.style.width = active.offsetWidth + "px";
  ind.style.transform = `translateX(${active.offsetLeft - ind.offsetLeft}px)`; // offsetLeft ignores the transform
}

function setActive(group, btn) {
  group.querySelectorAll("button").forEach((b) => b.classList.toggle("active", b === btn));
}

// Skills add to / remove from the chart; "Overall" removes every skill
function selectSkill(name) {
  if (name === "Overall") {
    state.series = state.series.filter((s) => s.kind !== "skill");
    syncSelectedSkill();
    return render();
  }
  toggleSeries("skill", name);
}

$("refresh-btn").addEventListener("click", refresh);

$("periods").addEventListener("click", (e) => {
  const btn = e.target.closest("button[data-period]");
  if (!btn) return;
  setActive($("periods"), btn);
  state.period = btn.dataset.period;
  render();
});

$("chart-mode").addEventListener("click", (e) => {
  const btn = e.target.closest("button[data-mode]");
  if (!btn) return;
  setActive($("chart-mode"), btn);
  state.chartMode = btn.dataset.mode;
  state.modeBeforeSel = null; // picked by hand: keep it after the selection is cleared
  renderChart(ctx());
});

$("skill-sort").addEventListener("click", (e) => {
  const btn = e.target.closest("button[data-sort]");
  if (!btn) return;
  setActive($("skill-sort"), btn);
  state.skillSort = btn.dataset.sort;
  renderSkills(ctx());
});

$("skills-grid").addEventListener("click", (e) => {
  const el = e.target.closest("[data-skill]");
  if (el) selectSkill(el.dataset.skill);
});

$("detail").addEventListener("click", (e) => {
  if (e.target.closest("#back-overall")) return selectSkill("Overall");
  const close = e.target.closest("#item-close");
  if (close) return toggleSeries("item", close.dataset.id);
  const el = e.target.closest("[data-skill]");
  if (el) selectSkill(el.dataset.skill);
});

$("feed-filter").addEventListener("click", (e) => {
  const btn = e.target.closest("button[data-filter]");
  if (!btn) return;
  setActive($("feed-filter"), btn);
  state.feedFilter = btn.dataset.filter;
  savePrefs();
  renderFeed();
});
// Feed tabs as icons: every tab is its icon; the active one opens up to show its name (CSS .feed-filter).
// Icons are the locally saved ones (no downloads). "All" gets a small drawn stack icon.
{
  const FEED_TAB_ICONS = {
    level: wikiIcon("Stats_icon.png"), boss: wikiIcon("Combat_icon.png"), kill: skillIcon("Slayer"),
    clue: gameIcon("cluescrollsall"), clog: wikiIcon("Collection_log.png"), ca: caIcon("Elite"),
  };
  const ALL_SVG = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3 3 8l9 5 9-5z"/><path d="m3 12 9 5 9-5"/><path d="m3 16 9 5 9-5"/></svg>`;
  for (const b of $("feed-filter").querySelectorAll("button[data-filter]")) {
    const name = b.textContent.trim(), f = b.dataset.filter;
    b.title = name;
    b.setAttribute("aria-label", name);
    b.innerHTML = (FEED_TAB_ICONS[f] ? `<img src="${FEED_TAB_ICONS[f]}" alt="">` : ALL_SVG) + `<span>${esc(name)}</span>`;
  }
}

$("feed").addEventListener("click", (e) => {
  const more = e.target.closest("[data-more]");
  if (more) {
    const open = more.parentElement.classList.toggle("open");
    more.setAttribute("aria-expanded", open);
    more.textContent = open ? "Show Less" : `+${more.dataset.more} more`;
    return;
  }
  // Recent activity only jumps ("go to"): it never selects or filters anything on the dashboard.
  // Selecting / filtering stays on clicks inside the sections themselves.
  const sk = e.target.closest("[data-skill]"); // an XP chip
  if (sk) return feedGo(`skill:${sk.dataset.skill}`);
  const it = e.target.closest("[data-item]"); // an item chip inside a "+N slots" card
  if (it) return revealItem(it.dataset.item);
  const card = e.target.closest("[data-go]");
  if (card) feedGo(card.dataset.go);
});
$("feed").addEventListener("keydown", (e) => {
  const card = (e.key === "Enter" || e.key === " ") && e.target.closest?.("[data-go]");
  if (card) { e.preventDefault(); feedGo(card.dataset.go); }
});
function feedGoLabel(kind) { return ({ skill: "Skills", skills: "Skills", clog: "Collection Log", item: "the collection log item",
  ca: "Combat Achievements", boss: "Boss Kills", clue: "Clue Scrolls", kill: "Kills & Loot" })[kind]; }
// Scroll a list box (not the page) so the row is at its top
function scrollListTo(list, row) {
  if (list && row) list.scrollTop += row.getBoundingClientRect().top - list.getBoundingClientRect().top - 8;
}
function feedGo(go) {
  const [kind, ...rest] = go.split(":"), name = rest.join(":");
  if (kind === "item") return revealItem(name);
  if (kind === "ca") return revealCaTask(name);
  if (kind === "kill") return revealKill(name);
  if (kind === "clog") { jumpTo($("clog-card")); return flash($("clog-card")); }
  if (kind === "skill" || kind === "skills") {
    jumpTo($("sec-skills"));
    return flash(name ? [...$("skills-grid").querySelectorAll("[data-skill]")].find((x) => x.dataset.skill === name) : $("sec-skills"));
  }
  if (kind === "boss") {
    const row = [...$("boss-list").querySelectorAll("[data-boss]")].find((x) => x.dataset.boss === name);
    scrollListTo($("boss-list"), row);
    jumpTo($("sec-bosses"));
    return flash(row);
  }
  if (kind === "clue") {
    jumpTo($("sec-bosses"));
    return flash($("clue-grid").querySelector(`[data-clue="${CSS.escape(name)}"]`));
  }
}

function jumpTo(el) {
  pinned = null; // a deliberate move: don't let "clicks never move the page" undo it
  const top = el.getBoundingClientRect().top + window.scrollY - document.querySelector(".topbar").offsetHeight - 16;
  window.scrollTo({ top: Math.max(0, top), behavior: "instant" });
}
function flash(el) {
  if (!el) return;
  el.classList.remove("flash");
  void el.offsetWidth; // restart the animation
  el.classList.add("flash");
}
// Pets: the Pets card. Other items: open their category in "Collection Log Items" (right tab, scrolled to it).
function revealItem(id) {
  const cl = state.clog;
  if (!cl) return;
  id = String(id);
  if (cl.petIds.includes(id)) {
    jumpTo($("pets-card"));
    return flash($("pets-card").querySelector(`[data-tile="${id}"]`));
  }
  const cat = [...cl.catIndex.entries()].find(([, c]) => c.ids.includes(id));
  if (!cat) return;
  state.clogGroup = cat[1].group;
  state.clogOpen = cat[0];
  savePrefs();
  renderClogItems();
  const box = $("clog-items-card"), list = box.querySelector(".cat-list"), row = list.querySelector(".cat.open");
  list.scrollTop += row.getBoundingClientRect().top - list.getBoundingClientRect().top;
  jumpTo(box);
  flash(row.querySelector(`[data-tile="${id}"]`));
}
// Combat task: its boss in the Combat achievements card, every task shown, the task highlighted
function revealCaTask(name) {
  const t = caData().tasks.find((x) => x.name === name);
  if (!t || $("ca-card").hidden) return;
  state.caPick = t.monster;
  state.caTier = null;
  state.caStatus = "all";
  state.caSearch = "";
  savePrefs();
  renderCa();
  caMoreRows(Infinity); // the task may be past the first rows
  const list = $("ca-card").querySelector(".ca-list");
  const row =[...list.querySelectorAll("[data-ca-name]")].find((r) => r.dataset.caName === name);
  if (row) list.scrollTop += row.getBoundingClientRect().top - list.getBoundingClientRect().top - 8;
  jumpTo($("ca-card"));
  flash(row);
}

$("heatmap").addEventListener("mouseover", showTip);
$("heatmap").addEventListener("mouseleave", () => ($("tip").hidden = true));
$("skills-grid").addEventListener("mouseover", showSkillTip);
$("skills-grid").addEventListener("mouseleave", () => ($("tip").hidden = true));

$("boss-sort").addEventListener("click", (e) => {
  const btn = e.target.closest("button[data-sort]");
  if (!btn) return;
  setActive($("boss-sort"), btn);
  state.bossSort = btn.dataset.sort;
  renderBosses(ctx());
  $("boss-list").scrollTop = 0;
});

$("boss-list").addEventListener("click", (e) => {
  const el = e.target.closest("[data-boss]");
  if (!el) return;
  toggleSeries("boss", el.dataset.boss);
  if (isSel("boss", el.dataset.boss)) showBossClog(el.dataset.boss);
});
// Selecting a boss opens its category in "Collection Log Items". Only the item list
// scrolls; the page stays where it is.
function showBossClog(name) {
  const cat = state.clog && bossCategory(name);
  if (!cat) return;
  state.clogGroup = state.clog.catIndex.get(cat).group;
  state.clogOpen = cat;
  savePrefs();
  renderClogItems();
  const list = $("clog-items-card").querySelector(".cat-list"), row = list.querySelector(".cat.open");
  list.scrollTop += row.getBoundingClientRect().top - list.getBoundingClientRect().top;
  flash(row);
}

$("clue-grid").addEventListener("click", (e) => {
  const el = e.target.closest("[data-clue]");
  if (el) toggleSeries("clue", el.dataset.clue);
});

// ---------- selection: chips in the top bar (desktop), floating Clear (phone) ----------

function bucketLabel(key, unit) {
  const d = new Date(key);
  if (unit === "hour") return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric" });
  if (unit === "week") return "Week of " + d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  if (unit === "month") return d.toLocaleDateString(undefined, { month: "short", year: "numeric" });
  return d.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
}

function renderSelection() {
  // Each selection's chip wears its chart color, so the chips double as the legend
  const chips = state.series.map((s, i) => ({
    what: i, label: seriesInfo(s).label, color: s.color,
    boss: s.kind === "boss" ? s.name : null,
    img: s.kind === "skill" ? skillIcon(s.name) : s.kind === "clue" ? gameIcon("cluescrolls" + s.name) : s.kind === "clog" ? wikiIcon("Collection_log.png") : s.kind === "item" ? itemIcon(s.name) : null,
  }));
  if (state.pick) chips.push({ what: "pick", label: bucketLabel(state.pick.key, state.pick.unit), day: true });

  $("float-sel").hidden = !chips.length;
  $("float-count").textContent = state.series.length > 1 ? state.series.length : "";
  const bar = $("sel-bar");
  bar.hidden = !chips.length;
  bar.innerHTML = chips.length ? `<span class="sel-label">Viewing</span>` + chips.map((c) => `
    <span class="sel-chip ${c.day ? "day" : ""}" ${c.color ? `style="--tier:${c.color}"` : ""}>
      <button type="button" class="sel-go" title="Show on the Chart">
        ${c.color ? "<i class=\"sel-dot\"></i>" : ""}
        ${c.day ? `<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><path fill="currentColor" d="M7 2v2H5a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2h-2V2h-2v2H9V2H7zm-2 7h14v10H5V9z"/></svg>`
          : c.boss ? `<span class="sel-icon" ${bossIconHtml(c.boss)}</span>` : `<span class="sel-icon"><img src="${c.img}" alt=""></span>`}
        <span>${esc(c.label)}</span>
      </button>
      <button type="button" class="sel-x" data-clear="${c.what}" title="Remove ${esc(c.label)}" aria-label="Remove ${esc(c.label)}">✕</button>
    </span>`).join("")
    + (chips.length > 1 ? `<button type="button" class="sel-all" data-clear="all">Clear All</button>` : "") : "";
}

$("sel-bar").addEventListener("click", (e) => {
  const x = e.target.closest("[data-clear]");
  if (x) {
    const what = x.dataset.clear;
    if (what === "all") return clearSelection();
    if (what === "pick") return pickBar(null);
    state.series.splice(Number(what), 1);
    syncSelectedSkill();
    return render();
  }
  if (e.target.closest(".sel-go")) {
    const target = e.target.closest(".day") && !$("bar-insight").hidden ? $("bar-insight") : document.querySelector(".chart-card");
    target.scrollIntoView({ behavior: "smooth", block: "start" });
  }
});

// "Clear": back to Overall XP with no boss, clue or day selected
function clearSelection() {
  state.series = [];
  state.selected = "Overall";
  state.detailItem = null;
  state.pick = null;
  restoreChartMode();
  render();
}
$("chart-clear").addEventListener("click", clearSelection);
$("float-chart").addEventListener("click", () => document.querySelector(".chart-card").scrollIntoView({ behavior: "smooth", block: "start" }));

$("boss-search").addEventListener("input", (e) => {
  state.bossQuery = e.target.value;
  renderBosses(ctx());
});

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  clearSelection();
});

window.addEventListener("resize", moveIndicator);
setInterval(updateRelativeTime, 30000);

// OSRS daily reset happens at 00:00 UTC
function updateResetTimer() {
  const now = new Date();
  const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  const s = Math.floor((next - now) / 1000);
  const pad = (n) => String(n).padStart(2, "0");
  $("reset-countdown").textContent = `${pad(Math.floor(s / 3600))}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`;
  $("reset-timer").classList.toggle("soon", s < 3600);
  $("reset-timer").title = `OSRS daily reset at ${new Date(next).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })} your time (00:00 UTC)`;
}
updateResetTimer();
setInterval(updateResetTimer, 1000);

// Clicking never moves the page. Clicks re-render parts of the page; if that shifts what you were
// looking at, scroll back by the same amount, instantly (the page otherwise scrolls smoothly).
// Anchor: the clicked element, or, for clicks in the sticky feed / top bar (which never appear to move),
// whatever is in the middle of the main column. Buttons meant to take you to the chart are left alone.
let pinned = null;
function pinSpot(e) {
  pinned = null;
  const t = e.target instanceof Element ? e.target : null;
  if (!t || t.closest(".sel-go, #float-chart, #sec-nav, #nav-sheet, .bank-more-n")) return;
  let anchor = t;
  if (t.closest(".side-col, .topbar")) {
    const r = document.querySelector(".main-col")?.getBoundingClientRect();
    anchor = r && document.elementFromPoint(r.left + r.width / 2, innerHeight / 2);
    if (!anchor || !anchor.closest(".main-col")) return;
  }
  const holder = anchor.parentElement?.closest("[id]");
  pinned = { anchor, holder, top: anchor.getBoundingClientRect().top, hTop: holder?.getBoundingClientRect().top };
}
function restoreSpot() {
  if (!pinned) return;
  const { anchor, holder, top, hTop } = pinned;
  pinned = null;
  // the anchor itself may have been re-rendered away; then its nearest surviving container with an id
  const shift = anchor.isConnected ? anchor.getBoundingClientRect().top - top
    : holder?.isConnected ? holder.getBoundingClientRect().top - hTop : 0;
  if (Math.abs(shift) >= 1) window.scrollTo({ top: window.scrollY + shift, behavior: "instant" });
}
for (const type of ["click", "keydown"]) {
  window.addEventListener(type, pinSpot, true); // before any handler runs
  window.addEventListener(type, restoreSpot); // after they all ran (same frame, before paint)
}

// ---------- section navigation (left rail) ----------
// Jumps instantly (no smooth scroll through the long page) to just below the sticky top bar.
const navButtons = [...document.querySelectorAll("#sec-nav [data-target]")];
$("sec-nav").addEventListener("click", (e) => {
  const b = e.target.closest("[data-target]");
  const el = b && $(b.dataset.target);
  if (!el) return;
  jumpTo(el);
  markNav(b.dataset.target);
});
function markNav(id) {
  for (const b of navButtons) b.classList.toggle("active", b.dataset.target === id);
}
// Sections without data (nothing synced yet, ...) are hidden; so are their buttons
function syncNav() {
  for (const b of navButtons) b.hidden = !!$(b.dataset.target)?.closest("[hidden]");
}
// Highlight the section at the top of the screen. IntersectionObserver: no work while scrolling.
// The band starts just under the sticky top bar, which is taller on phones (two rows): rebuilt when its
// height changes, otherwise a section hidden behind the bar would count as "on screen".
const navSeen = new Map();
let navObserver = null, navBarH = 0;
function watchNav() {
  const h = document.querySelector(".topbar").offsetHeight;
  // The pinned activity panel and the section rail sit just below the bar (equal gap above and below the panel)
  document.documentElement.style.setProperty("--topbar-h", `${h}px`);
  if (h === navBarH && navObserver) return;
  navBarH = h;
  navObserver?.disconnect();
  navSeen.clear();
  navObserver = new IntersectionObserver((entries) => {
    for (const en of entries) navSeen.set(en.target.id, en.isIntersecting);
    const cur = navButtons.find((b) => !b.hidden && navSeen.get(b.dataset.target));
    if (cur) markNav(cur.dataset.target);
  }, { rootMargin: `-${h + 20}px 0px -55% 0px` });
  for (const b of navButtons) { const el = $(b.dataset.target); if (el && b.dataset.target !== "sec-activity") navObserver.observe(el); }
}
new ResizeObserver(watchNav).observe(document.querySelector(".topbar")); // also runs once right away

// Phones/narrow windows: the strip above scrolls away with the page, so once it's off screen a floating
// "Sections" button (bottom right) opens the same list. Wide screens keep the sticky rail (CSS hides this).
const navFab = $("nav-fab"), navSheet = $("nav-sheet");
function closeNavSheet() {
  navSheet.hidden = true;
  navFab.setAttribute("aria-expanded", "false");
}
new IntersectionObserver(([en]) => {
  navFab.hidden = en.isIntersecting || $("dashboard").hidden;
  if (navFab.hidden) closeNavSheet();
}).observe($("sec-nav"));
navFab.addEventListener("click", () => {
  if (!navSheet.hidden) return closeNavSheet();
  // Built on open: same buttons, icons and hidden sections as the strip, current section highlighted
  navSheet.innerHTML = navButtons.filter((b) => !b.hidden).map((b) =>
    `<button type="button" role="menuitem" data-target="${b.dataset.target}" class="${b.classList.contains("active") ? "active" : ""}">${b.innerHTML}</button>`).join("");
  navSheet.hidden = false;
  navFab.setAttribute("aria-expanded", "true");
});
navSheet.addEventListener("click", (e) => {
  const b = e.target.closest("[data-target]");
  const el = b && $(b.dataset.target);
  closeNavSheet();
  if (!el) return;
  jumpTo(el);
  markNav(b.dataset.target);
});
document.addEventListener("click", (e) => { if (!navSheet.hidden && !e.target.closest("#nav-sheet, #nav-fab")) closeNavSheet(); });
// Esc with the menu open only closes the menu (not also "clear selection")
window.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !navSheet.hidden) { e.stopPropagation(); closeNavSheet(); navFab.focus(); }
}, true);

loadPrefs(); // last period, chart mode, sorts and tabs used on this device

if (window.SNAPSHOT) {
  // Read-only phone snapshot: the data is baked into the page, there is no server to refresh
  const pill = document.createElement("span");
  pill.className = "snapshot-pill";
  pill.title = "A saved copy of your stats. It doesn't update.";
  pill.textContent = "Snapshot";
  $("refresh-btn").replaceWith(pill);
  state.clogRaw = window.SNAPSHOT_CLOG ?? null;
  state.progress = window.SNAPSHOT_PROGRESS ?? null;
  state.diaryInfo = window.SNAPSHOT_DIARIES ?? null;
  state.miniquests = window.SNAPSHOT_MINIQUESTS ?? [];
  state.questReqs = window.SNAPSHOT_QUEST_REQS ?? null;
  state.caInfo = window.SNAPSHOT_CA ?? null;
  state.caHistory = window.SNAPSHOT_CA_HISTORY ?? [];
  state.bankRaw = window.SNAPSHOT_BANK ?? null;
  setHistory(window.SNAPSHOT);
} else if (location.protocol === "file:") {
  $("empty").hidden = false;
  $("empty-title").textContent = "Start the dashboard with start.bat";
  $("empty-text").textContent = "Double-click start.bat (not index.html) so the dashboard can reach the hiscores.";
  $("refresh-btn").disabled = true;
} else {
  // Player name from the server's settings.json. No name yet (first start): the setup card asks for it.
  fetch("/api/settings", { cache: "no-cache" }).then((r) => r.ok ? r.json() : null).catch(() => null).then((s) => {
    if (s && !s.player) { showSetup(); return; }
    if (s?.player) applyPlayer(s.player);
    if (s?.womOffer) $("wom-offer").hidden = false;
    loadHistory().catch((e) => toast(e.message, "error"));
  });
}

function applyPlayer(name) {
  document.title = `${name} · OSRS Progress`;
  $("hiscore-link").href = `https://secure.runescape.com/m=hiscore_oldschool/hiscorepersonal.ws?user1=${encodeURIComponent(name)}`;
}

// ---------- first start: player name, then the optional Wise Old Man import ----------
function showSetup() {
  state.needsSetup = true;
  $("empty").hidden = true;
  $("dashboard").hidden = true;
  $("refresh-btn").disabled = true;
  $("setup").hidden = false;
  $("periods").hidden = true; // nothing to pick yet
  $("setup-name").focus();
}

$("setup").addEventListener("submit", async (e) => {
  e.preventDefault();
  const name = $("setup-name").value.trim();
  const err = $("setup-error"), btn = $("setup-go");
  const fail = (msg) => { err.textContent = msg; err.hidden = false; $("setup-name").focus(); };
  const useWom = $("setup-wom").checked;
  err.hidden = true;
  if (!/^[A-Za-z0-9 _-]{1,12}$/.test(name)) return fail("OSRS names are 1-12 letters, numbers, spaces, - or _.");
  btn.disabled = true; btn.classList.add("loading");
  btn.querySelector("span").textContent = "Checking…";
  try {
    const res = await fetch("/api/setup", { method: "POST", body: JSON.stringify({ player: name }) });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) return fail(body.error || `Setup failed (${res.status})`);
    state.needsSetup = false;
    $("periods").hidden = false;
    $("setup").hidden = true;
    applyPlayer(name);
    state.cooldownUntil = Date.now() + COOLDOWN_S * 1000;
    tickCooldown();
    await loadClog();
    setHistory(body);
    toast(`Welcome, ${name}! First snapshot saved.`, "success");
    $("wom-offer").hidden = !useWom;
    answerWom(useWom); // runs on while the dashboard shows; if it fails the banner stays to try again
  } catch {
    fail("Could not reach the dashboard server. Is start.bat still running?");
  } finally {
    btn.disabled = false; btn.classList.remove("loading");
    btn.querySelector("span").textContent = "Continue";
  }
});

async function answerWom(doImport) {
  const imp = $("wom-import"), skip = $("wom-skip");
  imp.disabled = skip.disabled = true;
  const head = document.querySelector("#wom-offer .wom-text strong"), headText = head.textContent;
  const sub = document.querySelector("#wom-offer .wom-text .muted"), subText = sub.textContent;
  if (doImport) {
    imp.classList.add("loading"); imp.querySelector("span").textContent = "Importing…";
    head.textContent = "Importing From Wise Old Man";
    sub.textContent = "This can take a few minutes. Keep this page open.";
  }
  try {
    const res = await fetch("/api/wom", { method: "POST", body: JSON.stringify({ import: doImport }) });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || `Import failed (${res.status})`);
    $("wom-offer").hidden = true;
    if (doImport) {
      await loadHistory();
      toast(body.message || "Imported from Wise Old Man.", "success");
    }
  } catch (e) {
    toast(e.message, "error");
    // Nothing to import for this name: the server won't offer it again, so hide it now too
    if (/doesn't track|no snapshots|already imported/.test(e.message)) $("wom-offer").hidden = true;
  } finally {
    imp.disabled = skip.disabled = false; imp.classList.remove("loading");
    head.textContent = headText; sub.textContent = subText;
    imp.querySelector("span").textContent = "Import";
  }
}
$("wom-import").addEventListener("click", () => answerWom(true));
$("wom-skip").addEventListener("click", () => answerWom(false));
document.fonts?.ready.then(moveIndicator);
