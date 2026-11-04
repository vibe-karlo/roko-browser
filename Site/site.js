const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
const samples = ["weather in tokyo", "days until christmas", "250 usd in eur", "call petra tomorrow at 15", "time in new york", "15% of 240", "12 km"];
const tries = document.querySelectorAll("#tries .row");
let tryAt = 0;
const input = document.getElementById("ask"), out = document.getElementById("answer");

const zones = { tokyo: "Asia/Tokyo", london: "Europe/London", "new york": "America/New_York", paris: "Europe/Paris", zagreb: "Europe/Zagreb", berlin: "Europe/Berlin", sydney: "Australia/Sydney", dubai: "Asia/Dubai", "los angeles": "America/Los_Angeles", singapore: "Asia/Singapore" };
const units = { km: ["mi", .621371], mi: ["km", 1.60934], kg: ["lb", 2.20462], lb: ["kg", .453592], cm: ["in", .393701], in: ["cm", 2.54], m: ["ft", 3.28084], ft: ["m", .3048], l: ["gal", .264172] };
const rates = {};
let asked = 0;

function show(big, note, kind, small) {
  const b = out.querySelector("b");
  b.textContent = big; b.className = small ? "small" : "";
  out.querySelector("span").textContent = note;
  out.querySelector("i").textContent = kind;
  out.querySelector("use").setAttribute("href", kind === "To-do" ? "#i-todo" : kind === "Ask" ? "#i-browse" : kind === "Search" || kind === "Open" ? "#i-search" : "#i-equals");
  const q = input.value.trim().toLowerCase();
  let at = 0;
  const left = samples.filter(x => x !== q);
  for (const row of tries) { const t = left[(tryAt + at++) % left.length]; row.querySelector("b").textContent = t; row.dataset.q = t; }
}
const tidy = n => Number(n.toFixed(4)).toLocaleString("en-US", { maximumFractionDigits: 4 });

// A sum, read by hand: nothing typed here is ever run as code.
function sum(text) {
  let at = 0;
  const src = text.replace(/\s+/g, "").replace(/[x×]/g, "*").replace(/÷/g, "/");
  const atom = () => {
    if (src[at] === "-") { at++; return -atom(); }
    if (src[at] === "(") { at++; const v = add(); if (src[at++] !== ")") throw 0; return v; }
    const m = /^\d*\.?\d+/.exec(src.slice(at)); if (!m) throw 0;
    at += m[0].length; return parseFloat(m[0]);
  };
  const times = () => { let v = atom(); while (src[at] === "*" || src[at] === "/") { const o = src[at++]; const r = atom(); v = o === "*" ? v * r : v / r; } return v; };
  const add = () => { let v = times(); while (src[at] === "+" || src[at] === "-") { const o = src[at++]; const r = times(); v = o === "+" ? v + r : v - r; } return v; };
  const v = add();
  if (at !== src.length || !isFinite(v)) throw 0;
  return v;
}

async function rate(amount, from, to, stamp) {
  show("…", `Today's ${from} to ${to}`, "Rate");
  try {
    const key = from + to;
    rates[key] ??= (await (await fetch(`https://api.frankfurter.dev/v1/latest?base=${from}&symbols=${to}`)).json()).rates[to];
    if (stamp !== asked) return;
    show(`${(amount * rates[key]).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ${to}`, `${tidy(amount)} ${from} at today's rate`, "Rate");
  } catch { if (stamp === asked) show("Rates need a connection", "roko works it out in the bar", "Rate", true); }
}

const holidays = { christmas: [12, 25], "new year": [1, 1], "new years": [1, 1], halloween: [10, 31], "valentine's day": [2, 14], "valentines day": [2, 14] };
const months = "january february march april may june july august september october november december".split(" ");
function daysUntil(low) {
  const m = low.match(/^(?:how many )?days (?:until|till|to|since)\s+(.+?)\??$/); if (!m) return null;
  const since = /since/.test(low), name = m[1].replace(/^the /, "");
  let month, day, year;
  if (holidays[name]) [month, day] = holidays[name];
  else {
    let d = name.match(/^(\d{1,2})\.?\s+([a-z]+)\.?(?:\s+(\d{4}))?$/), e = name.match(/^([a-z]+)\s+(\d{1,2})(?:,?\s+(\d{4}))?$/);
    if (d) { day = +d[1]; month = months.findIndex(x => x.startsWith(d[2].slice(0, 3))) + 1; year = d[3] && +d[3]; }
    else if (e) { day = +e[2]; month = months.findIndex(x => x.startsWith(e[1].slice(0, 3))) + 1; year = e[3] && +e[3]; }
    else return null;
    if (!month) return null;
  }
  const now = new Date(), today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let when = new Date(year || now.getFullYear(), month - 1, day);
  if (!year && !since && when < today) when = new Date(now.getFullYear() + 1, month - 1, day);
  const n = Math.abs(Math.round((when - today) / 864e5));
  return [`${n} day${n === 1 ? "" : "s"}`, `${since ? "Since" : "Until"} ${when.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" })}`];
}

async function weather(place, stamp) {
  const name = (place || Intl.DateTimeFormat().resolvedOptions().timeZone.split("/").pop().replace(/_/g, " ")).trim();
  show("…", `Weather in ${name}`, "Weather");
  try {
    const geo = (await (await fetch(`https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(name)}&count=1`)).json()).results?.[0];
    if (!geo) { if (stamp === asked) show("Place not found", name, "Weather", true); return; }
    const c = (await (await fetch(`https://api.open-meteo.com/v1/forecast?latitude=${geo.latitude}&longitude=${geo.longitude}&current=temperature_2m,weather_code`)).json()).current;
    if (stamp !== asked) return;
    const code = c.weather_code, sky = code === 0 ? "Clear" : code < 3 ? "Partly cloudy" : code === 3 ? "Cloudy" : code < 50 ? "Fog" : code < 70 ? "Rain" : code < 80 ? "Snow" : code < 90 ? "Showers" : "Storms";
    show(`${Math.round(c.temperature_2m)}° ${sky}`, `Right now in ${geo.name}`, "Weather");
  } catch { if (stamp === asked) show("Weather needs a connection", "roko shows it in the bar", "Weather", true); }
}

function answer(raw) {
  const text = raw.trim(), low = text.toLowerCase(), stamp = ++asked;
  if (!text) return show("36", "15% of 240", "Sum");
  let m;
  const until = daysUntil(low); if (until) return show(until[0], until[1], "Date");
  if ((m = low.match(/^(?:weather|forecast)(?:\s+(?:in|for|at)\s+(.+))?$/)) || (m = low.match(/^(.+?)\s+weather$/))) return void weather(m[1], stamp);
  if ((m = low.match(/^([\d.]+)\s*%\s*of\s*([\d.]+)$/))) return show(tidy(m[1] / 100 * m[2]), text, "Sum");
  if ((m = low.match(/^([\d.,]+)\s*([a-z]{3})\s+(?:in|to)\s+([a-z]{3})$/))) return void rate(parseFloat(m[1].replace(",", "")), m[2].toUpperCase(), m[3].toUpperCase(), stamp);
  if ((m = low.match(/^([\d.]+)\s*(km|mi|kg|lb|cm|in|m|ft|l)(?:\s+(?:in|to)\s+[a-z]+)?$/))) { const [to, by] = units[m[2]]; return show(`${tidy(m[1] * by)} ${to}`, `${m[1]} ${m[2]}`, "Unit"); }
  if ((m = low.match(/^(?:time in\s+)?(.+?)(?:\s+time)?$/)) && zones[m[1]]) return show(new Date().toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: zones[m[1]] }), `Right now in ${m[1].replace(/\b\w/g, c => c.toUpperCase())}`, "Time");
  if (/^[\d\s.()+\-*/x×÷]+$/.test(low) && /\d/.test(low)) { try { return show(tidy(sum(low)), text, "Sum"); } catch {} }
  if (/^(https?:\/\/)?[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(\/\S*)?$/.test(low)) return show(low.replace(/^https?:\/\//, ""), "Opens the site, already loading", "Open", true);
  if (/\?$/.test(text) || /^(how|what|why|when|where|who|which|is|are|can|should|best)\b/.test(low)) return show(text, "Browse for me: reads the web and answers", "Ask", true);
  if (/^(call|buy|email|text|pay|book|remember|pick up|send)\b/.test(low) || /\b(tomorrow|tonight)\b/.test(low)) {
    const when = low.match(/\b(today|tonight|tomorrow)\b/), at = low.match(/\bat (\d{1,2})(?::(\d{2}))?\b/);
    const name = text.replace(/\s+(today|tonight|tomorrow)\b/i, "").replace(/\s+at \d{1,2}(:\d{2})?\b/i, "").replace(/\bpetra\b/i, "Petra");
    const hour = at ? +at[1] : 0, time = at ? `${hour % 12 || 12}:${at[2] || "00"} ${hour < 12 ? "AM" : "PM"}` : "";
    return show(name[0].toUpperCase() + name.slice(1), [when ? when[1][0].toUpperCase() + when[1].slice(1) : "New to-do", time && `at ${time}`].filter(Boolean).join(" "), "To-do", true);
  }
  show(text, "Search Google", "Search", true);
}
input.addEventListener("input", () => { stopped = true; answer(input.value); });

// On a touch screen the keyboard on the page is the keyboard: nothing jumps.
if (matchMedia("(pointer: coarse)").matches) input.setAttribute("inputmode", "none");
const kb = document.getElementById("kb");
let upper = false;
function put(text) { stopped = true; input.value = text; answer(text); }
kb.addEventListener("pointerdown", e => e.preventDefault());
kb.addEventListener("click", e => {
  const k = e.target.closest(".k")?.dataset.k; if (k === undefined) return;
  if (k === "123" || k === "abc") { for (const l of kb.querySelectorAll(".layer")) l.hidden = l.dataset.l !== k; return; }
  if (k === "shift") { upper = !upper; kb.classList.toggle("up", upper); return; }
  if (k === "go") { out.querySelector("span").textContent = "In roko, Go takes you there"; return; }
  if (k === "back") return put(input.value.slice(0, -1));
  put(input.value + (upper ? k.toUpperCase() : k));
  if (upper) { upper = false; kb.classList.remove("up"); }
});
for (const row of tries) row.addEventListener("click", () => { tryAt++; put(row.dataset.q); });

// The bar shows itself until someone reaches for it.
let stopped = still;
input.addEventListener("focus", () => { if (!stopped) { stopped = true; input.value = ""; answer(""); } });
const hero = document.getElementById("top");
(async () => {
  const wait = ms => new Promise(r => setTimeout(r, ms));
  for (let s = 0; !stopped; s = (s + 1) % samples.length) {
    await wait(s === 0 ? 1300 : 2600);
    if (stopped) return;
    if (scrollY > hero.offsetHeight) { s--; continue; }
    input.value = "";
    for (const c of samples[s]) { if (stopped) return; input.value += c; await wait(44); }
    if (!stopped) { tryAt = s + 1; answer(input.value); }
  }
})();

const puller = document.getElementById("puller"), compare = document.getElementById("compare");
const labA = document.getElementById("labA"), labB = document.getElementById("labB");
let pulled = false, compared = false;
function drag(box, name, axis, min, max, area, onUse, onSet) {
  const range = box.querySelector("input");
  const set = v => { v = Math.max(min, Math.min(max, v)); box.style.setProperty(name, v + "%"); range.value = v; onSet?.(v); };
  range.addEventListener("input", () => { onUse?.(); set(+range.value); });
  let on = false;
  const at = e => { const r = box.getBoundingClientRect(); set(axis === "x" ? (e.clientX - r.left) / r.width * 100 : (e.clientY - r.top) / r.height * 100); };
  area.addEventListener("pointerdown", e => { on = true; onUse?.(); area.setPointerCapture(e.pointerId); at(e); });
  area.addEventListener("pointermove", e => { if (on) at(e); });
  for (const end of ["pointerup", "pointercancel"]) area.addEventListener(end, () => { on = false; });
  return set;
}
drag(puller, "--p", "y", 6, 94, puller.querySelector(".grip"), () => { pulled = true; });
const shade = v => { labA.style.opacity = .5 + .5 * Math.min(1, v / 50); labB.style.opacity = .5 + .5 * Math.min(1, (100 - v) / 50); };
const setCompare = drag(compare, "--p", "x", 0, 100, compare, () => { compared = true; }, shade);
const splitter = document.getElementById("splitter"); drag(splitter, "--s", "y", 28, 76, splitter.querySelector(".grip"));

// The eye really switches: the note, or what private leaves out.
const privacy = document.getElementById("privacy"), eye = document.getElementById("eye"), ph = document.getElementById("privPh");
eye.addEventListener("click", () => {
  const open = privacy.classList.toggle("open");
  eye.setAttribute("aria-pressed", String(!open));
  ph.textContent = open ? "Search or enter address" : "Private search";
});

if (!still) {
  // The summary comes down over the page as it scrolls in, until someone takes it.
  let queued = false;
  const tall = document.getElementById("tall");
  const frame = () => {
    queued = false;
    const vh = innerHeight;
    if (!pulled) {
      const r = puller.getBoundingClientRect();
      puller.style.setProperty("--p", 6 + 88 * Math.max(0, Math.min(1, (vh * .8 - r.top) / (vh * .55))) + "%");
    }
    if (innerWidth >= 820) { const r = tall.getBoundingClientRect(); if (r.bottom > 0 && r.top < vh) tall.style.transform = `translateY(${(r.top + r.height / 2 - vh / 2) * -.05}px)`; }
    else tall.style.transform = "";
  };
  addEventListener("scroll", () => { if (!queued) { queued = true; requestAnimationFrame(frame); } }, { passive: true });
  frame();
  // Once, the first time it's seen: the line shows it moves.
  new IntersectionObserver((seen, io) => {
    if (!seen[0].isIntersecting) return;
    io.disconnect();
    const start = performance.now();
    const tick = t => {
      if (compared) return;
      const k = Math.min(1, (t - start) / 1800);
      setCompare(50 + 28 * Math.sin(k * Math.PI * 2) * (1 - k * .2) * (k < 1 ? 1 : 0));
      if (k < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, { threshold: .5 }).observe(compare);
}
