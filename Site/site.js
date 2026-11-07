const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
const samples = ["weather in tokyo", "days until christmas", "250 usd in eur", "call petra tomorrow at 15", "time in new york", "15% of 240", "12 km"];
const tries = document.querySelectorAll("#tries .row");
let tryAt = 0;
const input = document.getElementById("ask"), out = document.getElementById("answer");

const zones = { tokyo: "Asia/Tokyo", london: "Europe/London", "new york": "America/New_York", paris: "Europe/Paris", zagreb: "Europe/Zagreb", berlin: "Europe/Berlin", sydney: "Australia/Sydney", dubai: "Asia/Dubai", "los angeles": "America/Los_Angeles", singapore: "Asia/Singapore" };
const units = { km: ["mi", .621371], mi: ["km", 1.60934], kg: ["lb", 2.20462], lb: ["kg", .453592], cm: ["in", .393701], in: ["cm", 2.54], m: ["ft", 3.28084], ft: ["m", .3048], l: ["gal", .264172] };
const rates = {};
let asked = 0;

const askEnd = document.getElementById("askEnd");
function show(big, note, kind, small) {
  askEnd.classList.toggle("clear", !!input.value);
  askEnd.setAttribute("aria-label", input.value ? "Clear" : "Private search");
  const b = out.querySelector("b");
  b.textContent = big; b.className = small ? "small" : "";
  out.querySelector("span").textContent = note;
  out.querySelector("i").textContent = kind;
  out.querySelector("use").setAttribute("href", kind === "To-do" ? "#i-todo" : kind === "Ask" ? "#i-browse" : !kind || kind === "Search" || kind === "Open" ? "#i-search" : "#i-equals");
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
  } catch { if (stamp === asked) show("Rates need a connection", "Check yours and try again", "Rate", true); }
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
  } catch { if (stamp === asked) show("Weather needs a connection", "Check yours and try again", "Weather", true); }
}

function toDo(text) {
  const low = text.toLowerCase(), when = low.match(/\b(today|tonight|tomorrow)\b/), at = low.match(/\bat (\d{1,2})(?::(\d{2}))?\b/);
  const name = text.replace(/\s+(today|tonight|tomorrow)\b/i, "").replace(/\s+at \d{1,2}(:\d{2})?\b/i, "").replace(/\bpetra\b/i, "Petra");
  const hour = at ? +at[1] : 0, time = at ? `${hour % 12 || 12}:${at[2] || "00"} ${hour < 12 ? "AM" : "PM"}` : "";
  return { name: name[0].toUpperCase() + name.slice(1), when: [when ? when[1][0].toUpperCase() + when[1].slice(1) : "New to-do", time && `at ${time}`].filter(Boolean).join(" ") };
}

function answer(raw) {
  const text = raw.trim(), low = text.toLowerCase(), stamp = ++asked;
  out.classList.remove("typing");
  if (!text) return show("Type anything", "Or tap one below", "", true);
  let m;
  const until = daysUntil(low); if (until) return show(until[0], until[1], "Date");
  if ((m = low.match(/^(?:weather|forecast)(?:\s+(?:in|for|at)\s+(.+))?$/)) || (m = low.match(/^(.+?)\s+weather$/))) return void weather(m[1], stamp);
  if ((m = low.match(/^([\d.]+)\s*%\s*of\s*([\d.]+)$/))) return show(tidy(m[1] / 100 * m[2]), text, "Sum");
  if ((m = low.match(/^([\d.,]+)\s*([a-z]{3})\s+(?:in|to)\s+([a-z]{3})$/))) return void rate(parseFloat(m[1].replace(",", "")), m[2].toUpperCase(), m[3].toUpperCase(), stamp);
  if ((m = low.match(/^([\d.]+)\s*(km|mi|kg|lb|cm|in|m|ft|l)(?:\s+(?:in|to)\s+[a-z]+)?$/))) { const [to, by] = units[m[2]]; return show(`${tidy(m[1] * by)} ${to}`, `${m[1]} ${m[2]}`, "Unit"); }
  if ((m = low.match(/^(?:time in\s+)?(.+?)(?:\s+time)?$/)) && zones[m[1]]) return show(new Date().toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: zones[m[1]] }), `Right now in ${m[1].replace(/\b\w/g, c => c.toUpperCase())}`, "Time");
  if (/^[\d\s.()+\-*/x×÷]+$/.test(low) && /\d/.test(low)) { try { return show(tidy(sum(low)), text, "Sum"); } catch {} }
  if (/^(https?:\/\/)?[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(\/\S*)?$/.test(low)) return show(low.replace(/^https?:\/\//, ""), "Opens the site, already loading", "Open", true);
  if (/\?$/.test(text) || /^(how|what|why|when|where|who|which|is|are|can|should|best)\b/.test(low)) return show(text, "Browse for Me: reads the web and answers", "Ask", true);
  if (/^(call|buy|email|text|pay|book|remember|pick up|send)\b/.test(low) || /\b(tomorrow|tonight)\b/.test(low)) {
    const { name, when } = toDo(text);
    return show(name, when, "To-do", true);
  }
  show(text, "Search Google", "Search", true);
}
input.addEventListener("input", () => { stopped = true; chosen = false; answer(input.value); });

askEnd.addEventListener("click", e => {
  e.preventDefault();
  if (input.value) { stopped = true; input.value = ""; answer(""); return input.focus({ preventScroll: true }); }
  const on = askEnd.getAttribute("aria-pressed") !== "true";
  askEnd.setAttribute("aria-pressed", on);
  input.placeholder = on ? "Private search or address" : "Search or enter address";
  input.closest(".field").querySelector("use").setAttribute("href", on ? "#i-eyeClosed" : "#i-search");
});

// On a touch screen the keyboard on the page is the keyboard: nothing jumps.
if (matchMedia("(pointer: coarse)").matches) input.setAttribute("inputmode", "none");
const kb = document.getElementById("kb");
let upper = false, chosen = false;
for (const key of kb.querySelectorAll("button")) key.tabIndex = -1;
const go = () => { out.querySelector("span").textContent = "In roko, Go takes you there"; };
input.addEventListener("keydown", e => { if (e.key === "Enter") go(); });
// A whole-bar selection or a picked suggestion is replaced by the next key, as in a real bar.
const fresh = () => chosen || (document.activeElement === input && input.value && input.selectionStart === 0 && input.selectionEnd === input.value.length);
function put(text) { stopped = true; input.value = text; answer(text); }
kb.addEventListener("pointerdown", e => e.preventDefault());
kb.addEventListener("click", e => {
  const k = e.target.closest(".k")?.dataset.k; if (k === undefined) return;
  // iOS drops the bar's focus on a tap whatever pointerdown says, and the caret goes with it.
  if (coarse) input.focus({ preventScroll: true });
  if (k === "123" || k === "abc") { for (const l of kb.querySelectorAll(".layer")) l.hidden = l.dataset.l !== k; return; }
  if (k === "shift") { upper = !upper; kb.classList.toggle("up", upper); return; }
  if (k === "go") return go();
  const was = fresh() ? "" : input.value;
  chosen = false;
  if (k === "back") return put(was.slice(0, -1));
  put(was + (upper ? k.toUpperCase() : k));
  if (upper) { upper = false; kb.classList.remove("up"); }
});
for (const row of tries) row.addEventListener("click", () => { tryAt++; put(row.dataset.q); chosen = true; });

// The bar shows itself until someone reaches for it.
let stopped = still;
const coarse = matchMedia("(pointer: coarse)").matches;
let selecting = false;
input.addEventListener("focus", () => {
  if (!stopped) { stopped = true; input.value = ""; answer(""); }
  // A tap on the bar has to find the keys: they're the only keyboard a phone gets here.
  if (coarse) {
    // Safari's floating toolbar covers about 84 points of the page, and innerHeight doesn't say so.
    const over = input.closest(".device").getBoundingClientRect().bottom + 84 - innerHeight;
    const room = input.closest(".field").getBoundingClientRect().top - document.querySelector(".nav").getBoundingClientRect().bottom - 8;
    if (over > 0) scrollBy(0, Math.min(over, room));
    return;
  }
  selecting = true;
  input.select();
});
// The mouse button coming up would drop the selection the bar just made.
input.addEventListener("mouseup", e => { if (selecting) e.preventDefault(); selecting = false; });
input.addEventListener("blur", () => { selecting = false; });
input.addEventListener("keydown", () => { selecting = false; });
const hero = document.getElementById("top");
(async () => {
  const wait = ms => new Promise(r => setTimeout(r, ms));
  for (let s = 0; !stopped; s = (s + 1) % samples.length) {
    await wait(s === 0 ? 1300 : 2600);
    if (stopped) return;
    if (scrollY > hero.offsetHeight) { s--; continue; }
    input.value = ""; answer(""); out.classList.add("typing");
    for (const c of samples[s]) { if (stopped) return; input.value += c; await wait(44); }
    if (!stopped) { tryAt = s + 1; answer(input.value); }
  }
})();

const puller = document.getElementById("puller"), compare = document.getElementById("compare");
const labA = document.getElementById("labA"), labB = document.getElementById("labB");
let pulled = false, compared = false;
document.addEventListener("dragstart", e => { if (e.target.closest?.(".screen")) e.preventDefault(); });
function drag(box, name, axis, min, max, area, onUse, onSet) {
  const range = box.querySelector("input");
  const set = v => { v = Math.max(min, Math.min(max, v)); box.style.setProperty(name, v + "%"); range.value = v; onSet?.(v); };
  range.addEventListener("input", () => { onUse?.(); set(+range.value); });
  let on = false;
  const at = e => { const r = box.getBoundingClientRect(); set((typeof axis === "function" ? axis() : axis) === "x" ? (e.clientX - r.left) / r.width * 100 : (e.clientY - r.top) / r.height * 100); };
  // A finger on the whole picture may only be on its way down the page: it takes the divider once it moves sideways.
  let from = null;
  const take = e => { on = true; from = null; onUse?.(); area.setPointerCapture(e.pointerId); at(e); };
  area.addEventListener("pointerdown", e => {
    if (e.pointerType === "mouse") e.preventDefault();
    if (e.pointerType === "touch" && area === box) from = [e.clientX, e.clientY];
    else take(e);
  });
  area.addEventListener("pointermove", e => {
    if (from) { const x = Math.abs(e.clientX - from[0]), y = Math.abs(e.clientY - from[1]); if (x > 8 && x > y) take(e); return; }
    if (on) at(e);
  });
  for (const end of ["pointerup", "pointercancel"]) area.addEventListener(end, () => { on = false; from = null; });
  return set;
}
drag(puller, "--p", "y", 6, 100, puller.querySelector(".grip"), () => { pulled = true; });
const shade = v => { labA.style.setProperty("--shade", .5 + .5 * Math.min(1, v / 50)); labB.style.setProperty("--shade", .5 + .5 * Math.min(1, (100 - v) / 50)); compare.classList.toggle("end", v < .5 || v > 99.5); };
const setCompare = drag(compare, "--p", "x", 0, 100, compare, () => { compared = true; }, shade);
const splitter = document.getElementById("splitter"), splitSection = document.getElementById("split");
const splitShots = [[splitter.querySelector(".one img"), 0], [splitter.querySelector(".two img"), -.136]];
let turned = 0, split = 50, splitW = 0, splitH = 0, splitTaken = false, turning = false;
// The screen turns and each page stays upright: its picture swings around the middle of its pane,
// just large enough at every angle that no corner of the pane comes uncovered.
const layPages = () => {
  if (!turning) return;
  const angle = turned * Math.PI / 2, cos = Math.cos(angle), sin = Math.sin(angle);
  [split / 100, 1 - split / 100 - .03].forEach((part, i) => {
    const [img, lift] = splitShots[i], tall = part * splitH, wx = splitW / 2, hy = tall / 2;
    const y = -lift * splitW + hy + (wx * splitW / tall - hy) * turned;
    const size = Math.max((wx * cos + hy * sin) / wx, (wx * sin + hy * cos) / y);
    img.style.transform = `translate(${wx}px,${hy}px) rotate(${90 * turned}deg) scale(${size}) translate(${-wx}px,${-y}px)`;
  });
};
const setSplit = drag(splitter, "--s", () => turned > .5 ? "x" : "y", 28, 76, splitter.querySelector(".grip"), () => { splitTaken = true; }, v => { split = v; layPages(); });

// The same tap-tap as the app: the first marks it, the second hides it.
// Until someone taps, the scroll does the tapping: offer, newsletter, then app banner.
let playHide = () => {};
{
  const demo = document.getElementById("demo");
  const title = document.getElementById("hTitle"), sub = document.getElementById("hSub"), undo = document.getElementById("hUndo"), done = document.getElementById("hDone");
  const hidden = [];
  let marked = document.getElementById("adbox"), finished = false;
  const say = () => {
    undo.disabled = !hidden.length && !marked;
    done.textContent = finished ? "Again" : "Done";
    if (finished) { title.textContent = hidden.length ? "Stays gone on this site" : "Nothing hidden"; sub.textContent = hidden.length ? `${hidden.length} hidden` : "Tap Again to try it"; }
    else if (marked) { title.textContent = "Tap it again to hide it"; sub.textContent = `Marked: ${marked.dataset.h}`; }
    else { title.textContent = "Tap something to hide"; sub.textContent = hidden.length ? `${hidden.length} hidden` : "Tap it again to hide it"; }
  };
  const mark = el => { marked?.classList.remove("marked"); marked = el; el?.classList.add("marked"); };
  const queue = [document.getElementById("adbox"), demo.querySelector(".news"), demo.querySelector(".app")];
  let tapped = false, stage = 0;
  const hideNow = el => { el.style.height = el.offsetHeight + "px"; el.offsetHeight; el.classList.add("gone"); hidden.push(el); };
  const bring = el => { el.classList.remove("gone"); hidden.splice(hidden.indexOf(el), 1); setTimeout(() => { if (!el.classList.contains("gone")) el.style.height = ""; }, 340); };
  playHide = next => {
    if (tapped || next === stage) return;
    stage = next;
    queue.forEach((el, i) => {
      const gone = el.classList.contains("gone");
      if (i < next && !gone) hideNow(el);
      if (i >= next && gone) bring(el);
    });
    mark(queue[next] || null);
    say();
  };
  demo.addEventListener("pointerdown", e => { if (e.target.closest("button")) tapped = true; });
  demo.addEventListener("click", e => {
    const el = e.target.closest(".h"); if (!el || finished) return;
    if (el !== marked) { mark(el); return say(); }
    mark(null);
    hideNow(el);
    say();
  });
  undo.addEventListener("click", () => {
    if (finished) return;
    if (marked) mark(null);
    else { const el = hidden.pop(); if (el) { el.classList.remove("gone"); setTimeout(() => { el.style.height = ""; }, 340); } }
    say();
  });
  done.addEventListener("click", () => {
    mark(null);
    if (finished) { for (const el of hidden.splice(0)) { el.classList.remove("gone"); setTimeout(() => { el.style.height = ""; }, 340); } }
    finished = !finished;
    say();
  });
  say();
}

// The eye really switches: the note, or what private leaves out.
const privacy = document.getElementById("privacy"), eye = document.getElementById("eye"), ph = document.getElementById("privPh");
eye.addEventListener("click", () => {
  const open = privacy.classList.toggle("open");
  eye.setAttribute("aria-pressed", String(!open));
  ph.textContent = open ? "Search or enter address" : "Private search";
});

// The widget really ticks: a to-do goes, and the count with it.
const tdRows = [...document.querySelectorAll(".td-r")], tdLeft = document.getElementById("tdLeft"), tdDone = document.getElementById("tdDone");
const tdSay = () => {
  const left = tdRows.filter(r => !r.classList.contains("off")).length;
  tdLeft.textContent = left ? left + " left" : "";
  tdDone.hidden = left > 0;
  // All done, it says so, then the day starts over for the next person to try.
  if (!left) setTimeout(() => { for (const r of tdRows) { r.classList.remove("off"); r.disabled = false; } tdSay(); }, 2800);
};
for (const r of tdRows) r.addEventListener("click", () => { r.classList.add("off"); r.disabled = true; setTimeout(tdSay, 200); });

// The to-do bar really works: type a line, tap the answer, and it lands on the list.
const todoIn = document.getElementById("todoIn"), todoAdd = document.getElementById("todoAdd"), todoSearch = document.getElementById("todoSearch"), todoList = document.getElementById("todoList");
const todoSay = () => {
  const text = todoIn.value.trim();
  todoAdd.hidden = !text; todoSearch.hidden = !text; todoList.hidden = !!text;
  if (!text) return;
  const { name, when } = toDo(text);
  document.getElementById("todoName").textContent = name;
  document.getElementById("todoWhen").textContent = when;
  document.getElementById("todoText").textContent = text;
};
const todoLand = () => {
  const text = todoIn.value.trim();
  if (!text) return;
  const { name, when } = toDo(text), row = document.createElement("div");
  row.className = "row added";
  row.innerHTML = '<i class="tick"></i><div><b></b><span></span></div>';
  row.querySelector("b").textContent = name;
  row.querySelector("span").textContent = when;
  todoList.prepend(row);
  while (todoList.children.length > 3) todoList.lastChild.remove();
  todoIn.value = "";
  todoSay();
};
todoIn.addEventListener("input", todoSay);
todoIn.addEventListener("keydown", e => { if (e.key === "Enter") { e.preventDefault(); todoLand(); } });
todoAdd.addEventListener("click", todoLand);
todoSay();

// The list really works: three shops, and things ticked off in each.
const shop = document.getElementById("shop"), shopTabs = [...shop.querySelectorAll(".shops button")], shopLists = [...shop.querySelectorAll(".aisles")];
const shopCount = () => {
  for (const tab of shopTabs) {
    const left = shop.querySelectorAll(`[data-for=${tab.dataset.shop}] .item[aria-pressed=false]`).length;
    tab.querySelector("em").textContent = left || "";
  }
};
for (const tab of shopTabs) tab.addEventListener("click", () => {
  for (const each of shopTabs) each.setAttribute("aria-pressed", String(each === tab));
  for (const list of shopLists) list.hidden = list.dataset.for !== tab.dataset.shop;
});
for (const item of shop.querySelectorAll(".item")) item.addEventListener("click", () => {
  item.setAttribute("aria-pressed", String(item.getAttribute("aria-pressed") !== "true"));
  shopCount();
});

// Hold to speak, as in the app: the capsule fills, then listens, and the
// words come into the bar until the finger lifts. The words are written here.
const hold = document.getElementById("spHold"), spVal = document.getElementById("spVal"), spMain = document.getElementById("spMain"), spSub = document.getElementById("spSub");
const heard = ["days", "until", "Christmas"];
let spTimers = [], spCount = 0, spHeld = false;
const spSay = (main, sub) => { spMain.textContent = main; spSub.textContent = sub; };
const spRows = () => {
  const said = heard.slice(0, spCount).join(" ");
  spVal.textContent = said;
  spVal.classList.remove("ph");
  if (spCount < heard.length) return spSay(said, "Search");
  const now = new Date(), day = new Date(now.getFullYear(), 11, 25);
  if (now > day) day.setFullYear(day.getFullYear() + 1);
  const days = Math.ceil((day - now) / 864e5);
  spSay(days === 1 ? "1 day" : days + " days", "Until 25 December");
};
const spStart = () => {
  if (spHeld) return;
  spHeld = true;
  spCount = 0;
  spVal.textContent = "Search or enter address";
  spVal.classList.add("ph");
  spTimers.push(setTimeout(() => hold.classList.add("fill"), 120));
  spTimers.push(setTimeout(() => { hold.classList.add("on"); spSay("Listening", "Let go when you're done"); }, 360));
  heard.forEach((_, i) => spTimers.push(setTimeout(() => { spCount = i + 1; spRows(); }, 760 + i * 380)));
};
const spEnd = () => {
  if (!spHeld) return;
  spHeld = false;
  spTimers.forEach(clearTimeout);
  spTimers = [];
  hold.classList.remove("fill", "on");
  if (!spCount) spSay("Keep holding", "Let go when you're done");
};
hold.addEventListener("pointerdown", e => { hold.setPointerCapture(e.pointerId); spStart(); });
for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) hold.addEventListener(type, spEnd);
hold.addEventListener("contextmenu", e => e.preventDefault());
hold.addEventListener("keydown", e => { if (e.key === " " || e.key === "Enter") { e.preventDefault(); spStart(); } });
hold.addEventListener("keyup", spEnd);
hold.addEventListener("blur", spEnd);

if (!still) {
  const trio = document.getElementById("trio"), stage = trio.querySelector(".held"), chaps = [...stage.querySelectorAll(".chap")], seam = Object.assign(document.createElement("i"), { className: "seam" }), duoRun = document.getElementById("duoRun"), duoHeld = duoRun.querySelector(".held"), duoChaps = [...duoHeld.querySelectorAll(".chap")], duoSeam = Object.assign(document.createElement("i"), { className: "seam" }), newsRun = document.getElementById("newsRun"), newsHeld = newsRun.querySelector(".held"), newsChaps = [...newsHeld.querySelectorAll(".chap")], newsSeam = Object.assign(document.createElement("i"), { className: "seam" }), feedUI = document.getElementById("feedUI"), splitDevice = splitter.closest(".device");
  let splitFit = 1, splitUp = 0, pinned = false, stageTop = 0, phoneTall = 0, phoneMid = 0, duoTop = 0, duoTall = 0, duoMid = 0, newsTop = 0, newsTall = 0, newsMid = 0;
  // The tall height, which Safari's toolbar coming and going doesn't change: scenes measure from this alone.
  const stable = Object.assign(document.createElement("div"), { style: "position:fixed;top:0;width:0;height:100vh;visibility:hidden;pointer-events:none" });
  stable.setAttribute("aria-hidden", "true");
  document.body.append(stable);
  let vh0 = stable.offsetHeight, vw0 = innerWidth;
  // A pinned phone needs the height to stand in. Too short, and both scenes stay in plain flow.
  const pinTo = on => {
    if (on === pinned) return;
    pinned = turning = on;
    trio.classList.toggle("on", on); duoRun.classList.toggle("on", on); newsRun.classList.toggle("on", on); splitSection.classList.toggle("scrub", on);
    if (on) { stage.append(seam); duoHeld.append(duoSeam); newsHeld.append(newsSeam); } else { seam.remove(); duoSeam.remove(); newsSeam.remove(); feedUI.style.removeProperty("--m"); }
    splitter.querySelector(".two img").style.top = on ? "0" : "";
    if (on) return;
    turned = 0;
    splitDevice.style.transform = "";
    for (const [img] of splitShots) img.style.transform = "";
    trio.style.marginBottom = "";
    if (!compared) setCompare(50);
    if (!splitTaken) setSplit(50);
    playHide(0);
    if (!pulled) puller.style.setProperty("--p", "62%");
    for (const chap of [...chaps, ...duoChaps, ...newsChaps]) { chap.classList.remove("now", "under"); for (const name of ["--o", "--ty", "--clip"]) chap.style.removeProperty(name); }
  };
  // Measured once and on resize, never while scrolling.
  const measure = () => {
    vh0 = stable.offsetHeight;
    pinTo(vh0 >= 620);
    if (!pinned) return;
    stageTop = parseFloat(getComputedStyle(stage).top) || 0;
    phoneTall = chaps[0].querySelector(".device").offsetHeight;
    phoneMid = stage.offsetHeight / 2 + (innerWidth >= 1100 ? 26 : 97);
    duoTop = parseFloat(getComputedStyle(duoHeld).top) || 0;
    duoTall = duoChaps[0].querySelector(".device").offsetHeight;
    duoMid = duoHeld.offsetHeight / 2 + (innerWidth >= 1100 ? 26 : 116);
    newsTop = parseFloat(getComputedStyle(newsHeld).top) || 0;
    newsTall = newsChaps[0].querySelector(".device").offsetHeight;
    newsMid = newsHeld.offsetHeight / 2 + (innerWidth >= 1100 ? 26 : 116);
    splitW = splitter.offsetWidth; splitH = splitter.offsetHeight;
    const tall = splitDevice.offsetHeight;
    splitFit = Math.min(1, (innerWidth - 32) / tall);
    splitUp = innerWidth >= 1100 ? 0 : Math.max(0, (tall - splitDevice.offsetWidth * splitFit) / 2 * .7);
    // Turned sideways on a narrow screen, the phone leaves the stage's foot empty: the next section comes up into it.
    const turnedFoot = phoneMid - splitUp + splitDevice.offsetWidth * splitFit / 2;
    trio.style.marginBottom = innerWidth >= 1100 ? "" : -Math.max(0, stage.offsetHeight - turnedFoot) + "px";
    const line = splitSection.querySelector("h2"), [a, b] = line.querySelectorAll("span"), wide = innerWidth >= 1100;
    const air = b.offsetLeft - a.offsetLeft - a.offsetWidth, half = splitDevice.offsetWidth / 2 + 44;
    splitSection.style.setProperty("--lx", wide ? (air + b.offsetWidth - a.offsetWidth) / 2 - half + "px" : "0px");
    splitSection.style.setProperty("--rx", wide ? half + (b.offsetWidth - a.offsetWidth - air) / 2 + "px" : "0px");
    splitSection.style.setProperty("--lc", wide ? half + b.offsetWidth / 2 + "px" : "0px");
    splitSection.style.setProperty("--dy", wide ? phoneMid - line.offsetTop - line.offsetHeight / 2 + "px" : "0px");
    layPages();
  };
  measure();
  addEventListener("resize", () => {
    if (coarse && innerWidth === vw0) return;
    vw0 = innerWidth;
    lightDirty = true;
    measure();
    frame();
  });
  document.fonts?.ready.then(() => { measure(); frame(); });
  // A scene's pictures are ready before it arrives, so none of them pops in mid-scroll.
  // They wait until the page itself has loaded, so they never hold up the first screen.
  addEventListener("load", () => new IntersectionObserver((near, io) => {
    for (const { isIntersecting, target } of near) if (isIntersecting) {
      io.unobserve(target);
      for (const img of target.querySelectorAll("img")) { img.loading = "eager"; img.decode?.().catch(() => {}); }
    }
  }, { rootMargin: "400% 0px" }).observe(duoRun));
  // A keyboard reaching a demo that isn't showing brings it into view.
  stage.addEventListener("focusin", e => {
    if (!pinned) return;
    const at = chaps.indexOf(e.target.closest(".chap"));
    if (at < 0 || chaps[at].classList.contains("now")) return;
    scrollTo(0, trio.getBoundingClientRect().top + scrollY - stageTop + [.5, 1.6, 3.1][at] * vh0);
  });
  duoHeld.addEventListener("focusin", e => {
    if (!pinned) return;
    const at = duoChaps.indexOf(e.target.closest(".chap"));
    if (at < 0 || duoChaps[at].classList.contains("now")) return;
    scrollTo(0, duoRun.getBoundingClientRect().top + scrollY - duoTop + [.5, 1.7][at] * vh0);
  });
  // The summary comes down over the page as it scrolls in, until someone takes it.
  let queued = false;
  // The light: one soft radial glow, drawn once and only moved, so a still page does no work.
  // Black at its rim, a little plum, then deepening to the brand's red-orange at its heart.
  const rise = document.createElement("canvas"), lightBox = document.createElement("div");
  lightBox.className = "sky"; lightBox.setAttribute("aria-hidden", "true"); rise.className = "rise";
  lightBox.append(rise); document.body.append(lightBox);
  document.documentElement.classList.add("lit");
  {
    const w = 480, h = 960, wash = new ImageData(w, h), px = wash.data;
    const stops = [[0, 15, 15, 14], [.14, 30, 15, 20], [.34, 62, 20, 25], [.58, 108, 30, 26], [.8, 146, 44, 30], [1, 172, 54, 32]];
    // A pixel's colour depends only on its distance from the heart, so the colours are worked out once and looked up.
    const steps = 4096, far = 3, ramp = new Float32Array((steps + 1) * 3);
    for (let s = 0; s <= steps; s++) {
      const t = Math.exp(-((s / steps * far / .64) ** 1.15));
      let i = 0;
      while (i < stops.length - 2 && t > stops[i + 1][0]) i++;
      const from = stops[i], to = stops[i + 1], k = (t - from[0]) / (to[0] - from[0]);
      for (let c = 0; c < 3; c++) ramp[s * 3 + c] = from[c + 1] + (to[c + 1] - from[c + 1]) * k;
    }
    for (let y = 0, at = 0; y < h; y++) {
      const down = y / h * 2 - 1.62;
      for (let x = 0; x < w; x++, at += 4) {
        const across = (x / w - .44) * .95, s = ((across * across + down * down) / far * steps | 0) * 3, n = (Math.random() - .5) * 2.4;
        px[at] = ramp[s] + n; px[at + 1] = ramp[s + 1] + n; px[at + 2] = ramp[s + 2] + n; px[at + 3] = 255;
      }
    }
    rise.width = w; rise.height = h;
    rise.getContext("2d").putImageData(wash, 0, 0);
  }
  let levels = [], footTop = 0, lightDirty = true, navY = scrollY;
  const navBar = document.querySelector(".nav");
  const foot = document.querySelector("footer");
  const mapLight = () => {
    lightDirty = false;
    const top = el => el.getBoundingClientRect().top + scrollY, vh = vh0;
    const run = top(document.getElementById("trio")), ask = top(document.getElementById("duoRun")), reading = top(document.getElementById("newsRun"));
    // The light only ever rises down the page, slowly, and never answers to how fast you scroll.
    levels = [
      [0, .2, .85], [top(document.getElementById("fast")), .23, .85], [top(document.getElementById("smart")), .26, .85],
      [ask + vh * 2.2, .3, .85], [reading, .31, .85], [reading + vh * 2.2, .35, .85],
      [run, .36, .85], [run + vh * 4, .5, .85], [top(document.getElementById("rest")), .51, .85],
      [top(foot) - vh, .54, .85],
    ].sort((a, b) => a[0] - b[0]);
    footTop = top(foot);
  };
  const moveLight = vh => {
    if (lightDirty) mapLight();
    const y = scrollY;
    if (vw0 <= 600 && Math.abs(y - navY) > 6) { navBar.classList.toggle("away", y > navY && y > vh * .4); navY = y; }
    let at = 1;
    while (at < levels.length - 1 && levels[at][0] < y) at++;
    const [a, b] = [levels[at - 1], levels[at]], k = Math.max(0, Math.min(1, (y - a[0]) / (b[0] - a[0] || 1))), s = k * k * (3 - 2 * k);
    const line = footTop - y, foot2 = Math.max(0, Math.min(1, (vh - line) / (vh * .9)));
    // The wash is twice the screen tall: this is how far down it the screen's foot has come.
    const reach = .72 + (a[1] + (b[1] - a[1]) * s) * .75 + .5 * foot2 * foot2;
    rise.style.transform = `translateY(${(1 - reach) * vh}px)`;
  };
  new ResizeObserver(() => { lightDirty = true; if (!queued) { queued = true; requestAnimationFrame(frame); } }).observe(document.body);
  const frame = () => {
    queued = false;
    const vh = vh0;
    moveLight(vh);
    if (!pulled && !pinned) {
      const r = puller.getBoundingClientRect();
      puller.style.setProperty("--p", 6 + 56 * Math.max(0, Math.min(1, (vh * .8 - r.top) / (vh * .55))) + "%");
    }
    if (!pinned) return;
    // Everything plays by scroll position alone, so scrolling back plays it backwards.
    const clamp = v => Math.max(0, Math.min(1, v));
    const ease = v => { v = clamp(v); return v * v * (3 - 2 * v); };
    // Between things, the next screen rises inside the same phone, under one line.
    const paint = (list, line, risen, showing, on, leaves, mid, tall) => {
      list.forEach((chap, i) => {
        chap.style.setProperty("--o", showing[i]);
        chap.style.setProperty("--ty", (i < on ? -14 : i > on ? 14 : leaves[i] ? -14 : 14) * (1 - showing[i]) + "px");
        chap.style.setProperty("--clip", risen[i] < 1 ? `inset(${(1 - risen[i]) * 100}% -8px -8px -8px)` : "none");
        chap.classList.toggle("now", i === on);
        chap.classList.toggle("under", i < list.length - 1 && risen[i + 1] >= 1);
      });
      const moving = risen.find(v => v > 0 && v < 1);
      line.style.opacity = moving === undefined ? 0 : 1;
      if (moving !== undefined) line.style.transform = `translateY(${mid + tall / 2 - 8 - moving * (tall - 14)}px)`;
    };
    const duoBox = duoRun.getBoundingClientRect();
    if (duoBox.bottom > -vh && duoBox.top < vh * 2) {
      const q = Math.max(0, Math.min(2.2, (duoTop - duoBox.top) / vh));
      if (!pulled) puller.style.setProperty("--p", 6 + 94 * ease(q / 1.05) + "%");
      paint(duoChaps, duoSeam, [1, ease((q - 1.2) / .35)], [1 - clamp((q - 1.2) / .17), clamp((q - 1.38) / .17)], q < 1.38 ? 0 : 1, [q > 1.2, false], duoMid, duoTall);
    }
    const newsBox = newsRun.getBoundingClientRect();
    if (newsBox.bottom > -vh && newsBox.top < vh * 2) {
      const q = Math.max(0, Math.min(2.2, (newsTop - newsBox.top) / vh));
      feedUI.style.setProperty("--m", ease((q - .15) / .75));
      paint(newsChaps, newsSeam, [1, ease((q - 1.2) / .35)], [1 - clamp((q - 1.2) / .17), clamp((q - 1.38) / .17)], q < 1.38 ? 0 : 1, [q > 1.2, false], newsMid, newsTall);
    }
    const box = trio.getBoundingClientRect();
    if (box.bottom < -vh || box.top > vh * 2) return;
    const p = Math.max(0, Math.min(4, (stageTop - box.top) / vh));
    if (!compared) setCompare(100 - 100 * ease((p - .05) / .9));
    playHide((v => v < .12 ? 0 : v < .42 ? 1 : v < .72 ? 2 : 3)((p - 1.55) / .85));
    paint(chaps, seam, [1, ease((p - 1.1) / .35), ease((p - 2.5) / .35)], [1 - clamp((p - 1.1) / .17), clamp((p - 1.28) / .17) * (1 - clamp((p - 2.5) / .17)), clamp((p - 2.68) / .17)], p < 1.28 ? 0 : p < 2.68 ? 1 : 2, [p > 1.1, p > 2.5, false], phoneMid, phoneTall);
    const k = (p - 2.85) / 1.15;
    {
      turned = innerWidth >= 1100 ? ease((k - .42) / .4) : ease((k - .25) / .38);
      splitSection.style.setProperty("--t", turned);
      splitSection.style.setProperty("--mid", Math.min(1, Math.sin(Math.PI * turned) * 2.4));
      splitSection.classList.toggle("side", turned > .5);
      splitDevice.style.transform = `translateY(${(innerWidth >= 1100 ? vh * .05 : -splitUp) * turned}px) rotate(${-90 * turned}deg) scale(${1 + (splitFit - 1) * turned})`;
      if (!splitTaken && !coarse) setSplit(50 + 13 * Math.sin(Math.PI * ease(k / .36)));
      else layPages();
    }
  };
  addEventListener("scroll", () => { if (!queued) { queued = true; requestAnimationFrame(frame); } }, { passive: true });
  frame();
}

// The scoreboard: one set of rows that moves to its new place for each measure.
const proofData = {
  speed: {
    unit: v => v.toFixed(2) + " s", low: true, head: "The fastest of ten browsers.",
    note: "Time from opening a link until half of the page is drawn, on CNN, Daily Mail, The Guardian, The Independent, Index.hr, the New York Post, The Sun and Wikipedia, sites each browser had opened before. Median of 24 runs each, in random order, measured from the screen.",
    method: " roko, Quiche, Arc Search, Lens and Brave are from 7 November 2026; the other five are from 5 to 6 November, so compare within a date first. iPhone 17 Pro, iOS 27.2. roko on 7 November was a test build of 0.1.4. Others on 5 to 6 November: Safari 27.2, Chrome 157, Firefox 159, Edge 156, DuckDuckGo 7.244. Yours will vary. ",
    values: { roko: 0.77, quiche: 1.48, arc: 2.87, lens: 2.91, firefox: 3.47, brave: 3.75, duckduckgo: 4.33, chrome: 4.96, safari: 4.96, edge: 5.46 },
  },
  block: {
    unit: v => v.toFixed(1) + " reached a page", low: true, head: "Blocks the most ads and trackers.",
    note: "Ad and tracker servers reached per page, by Peter Lowe's and Disconnect's lists, which roko doesn't draw on, leaving out cookie consent tools. Average of 40 runs each on 16 sites, from the phone's traffic. A browser stopped at a cookie wall reaches fewer.",
    values: { roko: 0.7, arc: 0.9, brave: 1.7, duckduckgo: 2.7, quiche: 4.2, firefox: 5.7, safari: 5.7, edge: 9.8, lens: 16.4, chrome: 16.4 },
  },
  first: {
    unit: v => v.toFixed(0) + " of 12", low: false, head: "First to the page, first time.",
    note: "How many of 12 sites none of these browsers had opened showed a readable page after 20 seconds, not a cookie wall, bot check or blank screen, judged by a reader who didn't know which browser was which. roko was also first to a readable page on 7 of the 10 sites any browser reached, with a median of 1.23 s. One run each, on AP News, Axios, ABC, Die Presse, Europe 1, Hindustan Times, Il Mattino, Il Post, Kurier, LCI, NOS and the NZ Herald.",
    method: " iPhone 17 Pro, iOS 27.2, 7 November 2026. roko 0.1.4, against the six browsers that drew first visits sooner than roko on 5 November. Yours will vary. ",
    values: { roko: 10, arc: 9, quiche: 5, firefox: 5, lens: 5, safari: 3, chrome: 3 },
  },
  clean: {
    unit: v => v.toFixed(0) + " of 6", low: false, head: "No ads, pop-ups or walls.",
    note: "How many of six ad-heavy sites showed no ad, pop-up or wall in five swipes down the page: CNN, Daily Mail, The Guardian, The Independent, the New York Post and The Sun. One run each, judged by eye.",
    values: { roko: 6, brave: 3, duckduckgo: 3, lens: 3, quiche: 2, arc: 2, firefox: 1, safari: 0, chrome: 0, edge: 0 },
  },
};
const proofMethod = " iPhone 17 Pro, iOS 27.2, 5 to 6 November 2026. roko 0.1.2, Safari 27.2, Chrome 157, Firefox 159, Edge 156, Brave 1.98, DuckDuckGo 7.244, Arc Search 1.49, Lens 1.1, Quiche. Yours will vary. ";
const runs = document.getElementById("runs");
if (runs) {
  const rows = [...runs.children], head = document.getElementById("proofHead"), note = document.getElementById("proofNote");
  const measures = [...document.querySelectorAll(".measures button")];
  let measure = "speed";
  const fill = (row, width) => { const bar = row.querySelector("i"); bar.style.width = width; bar.style.minWidth = parseFloat(width) ? "" : "0"; };
  const reads = document.getElementById("proofReads");
  const show = () => {
    const m = proofData[measure], view = m;
    const max = Math.max(...Object.values(view.values));
    const order = Object.keys(view.values).sort((a, b) => m.low ? view.values[a] - view.values[b] : view.values[b] - view.values[a]);
    runs.style.setProperty("--n", order.length);
    for (const row of rows) {
      const at = order.indexOf(row.dataset.b), value = view.values[row.dataset.b];
      row.hidden = at < 0;
      if (at < 0) continue;
      row.style.setProperty("--at", at);
      row.querySelector(".val").textContent = m.unit(value);
      fill(row, (value / max * 100) + "%");
    }
    head.textContent = view.head;
    reads.textContent = m.low ? "Shorter is better." : "Longer is better.";
    note.innerHTML = "";
    note.append(m.note + (m.method || proofMethod));
    const how = document.createElement("a");
    how.href = "https://github.com/vibe-karlo/roko-browser/tree/main/Scripts/compare/real-sites";
    how.textContent = "Run the test yourself.";
    note.append(how);
    for (const b of measures) b.setAttribute("aria-pressed", b.dataset.m === measure);
  };
  runs.classList.add("live");
  show();
  for (const b of measures) b.addEventListener("click", () => { measure = b.dataset.m; show(); });
  // Bars run out once as the board comes into view. They empty only just before
  // it's on screen, and fill on their own if the second signal never arrives.
  if (!still) {
    let emptied = false;
    const run = () => { if (emptied) { emptied = false; show(); } };
    const before = new IntersectionObserver(([e]) => {
      if (!e.isIntersecting || e.intersectionRatio > 0.02) { if (e.isIntersecting) before.disconnect(); return; }
      before.disconnect();
      for (const row of rows) fill(row, "0%");
      emptied = true;
      setTimeout(run, 2500);
    }, { rootMargin: "0px 0px 240px 0px", threshold: [0, 0.02] });
    before.observe(runs);
    new IntersectionObserver(([e], o) => { if (e.isIntersecting) { o.disconnect(); run(); } }, { threshold: 0.2 }).observe(runs);
  }
}

// The meters' small animations rest while they're off screen.
{
  const seen = new IntersectionObserver(all => { for (const e of all) e.target.classList.toggle("parked", !e.isIntersecting); });
  for (const m of document.querySelectorAll(".meter")) seen.observe(m);
}

// The nav says which part you're in, with its type and nothing bolted on.
{
  const parts = { fast: "#fast", proof: "#fast", smart: "#smart", clean: "#clean" };
  const links = [...document.querySelectorAll('.nav a.link[href^="#"]')];
  // One plate slides between the links, so the eye sees where you went from.
  const slide = document.createElement("i");
  slide.className = "slide";
  slide.setAttribute("aria-hidden", "true");
  const nav = document.querySelector(".nav");
  nav.prepend(slide);
  const place = () => {
    const now = links.find(l => l.hasAttribute("aria-current") && l.offsetWidth);
    slide.classList.toggle("on", !!now);
    if (!now) return slide.classList.remove("glide");
    slide.style.width = now.offsetWidth + 20 + "px";
    slide.style.transform = `translateX(${now.offsetLeft - 10}px)`;
    requestAnimationFrame(() => slide.classList.add("glide"));
  };
  const seen = new IntersectionObserver(entries => {
    for (const e of entries) {
      if (e.isIntersecting) for (const l of links) e.target.id in parts && parts[e.target.id] === l.getAttribute("href") ? l.setAttribute("aria-current", "true") : l.removeAttribute("aria-current");
    }
    place();
  }, { rootMargin: "-45% 0px -50% 0px" });
  addEventListener("resize", () => { slide.classList.remove("glide"); place(); });
  document.fonts?.ready.then(() => { slide.classList.remove("glide"); place(); });
  for (const s of document.querySelectorAll("header.hero,main>section")) seen.observe(s);
}
