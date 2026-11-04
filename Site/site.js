const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
const input = document.getElementById("ask"), out = document.getElementById("answer");

const zones = { tokyo: "Asia/Tokyo", london: "Europe/London", "new york": "America/New_York", paris: "Europe/Paris", zagreb: "Europe/Zagreb", berlin: "Europe/Berlin", sydney: "Australia/Sydney", dubai: "Asia/Dubai", "los angeles": "America/Los_Angeles", singapore: "Asia/Singapore" };
const units = { km: ["mi", .621371], mi: ["km", 1.60934], kg: ["lb", 2.20462], lb: ["kg", .453592], cm: ["in", .393701], in: ["cm", 2.54], m: ["ft", 3.28084], ft: ["m", .3048], l: ["gal", .264172] };
const rates = {};
let asked = 0;

function show(big, note, kind, small) {
  out.innerHTML = "";
  const b = document.createElement("b"); b.textContent = big; if (small) b.className = "small";
  const s = document.createElement("span"); s.textContent = note;
  const i = document.createElement("i"); i.textContent = kind;
  out.append(b, s, i);
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
    show(`${tidy(amount * rates[key])} ${to}`, `${tidy(amount)} ${from} at today's rate`, "Rate");
  } catch { if (stamp === asked) show("Rates need a connection", "roko works it out in the bar", "Rate", true); }
}

function answer(raw) {
  const text = raw.trim(), low = text.toLowerCase(), stamp = ++asked;
  if (!text) return show("15% of 240 = 36", "Answered right in the bar", "Sum");
  let m;
  if ((m = low.match(/^([\d.]+)\s*%\s*of\s*([\d.]+)$/))) return show(`${text} = ${tidy(m[1] / 100 * m[2])}`, "Answered right in the bar", "Sum");
  if ((m = low.match(/^([\d.,]+)\s*([a-z]{3})\s+(?:in|to)\s+([a-z]{3})$/))) return void rate(parseFloat(m[1].replace(",", "")), m[2].toUpperCase(), m[3].toUpperCase(), stamp);
  if ((m = low.match(/^([\d.]+)\s*(km|mi|kg|lb|cm|in|m|ft|l)(?:\s+(?:in|to)\s+[a-z]+)?$/))) { const [to, by] = units[m[2]]; return show(`${tidy(m[1] * by)} ${to}`, `${m[1]} ${m[2]}`, "Unit"); }
  if ((m = low.match(/^(?:time in\s+)?(.+?)(?:\s+time)?$/)) && zones[m[1]]) return show(new Date().toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: zones[m[1]] }), `Right now in ${m[1].replace(/\b\w/g, c => c.toUpperCase())}`, "Time");
  if (/^[\d\s.()+\-*/x×÷]+$/.test(low) && /\d/.test(low)) { try { return show(`= ${tidy(sum(low))}`, text, "Sum"); } catch {} }
  if (/^(https?:\/\/)?[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(\/\S*)?$/.test(low)) return show(low.replace(/^https?:\/\//, ""), "Opens the site", "Open", true);
  if (/\?$/.test(text) || /^(how|what|why|when|where|who|which|is|are|can|should|best)\b/.test(low)) return show(text, "Browse for Me reads the web and answers", "Ask", true);
  if (/^(call|buy|email|text|pay|book|remember|pick up|send)\b/.test(low) || /\b(tomorrow|tonight|on (mon|tues|wednes|thurs|fri|satur|sun)day)\b/.test(low)) return show(text[0].toUpperCase() + text.slice(1), /tomorrow/.test(low) ? "New to-do for tomorrow" : "New to-do", "To-do", true);
  show(text, "Searches with the engine you chose", "Search", true);
}
input.addEventListener("input", () => { stopped = true; answer(input.value); });

// The bar shows itself until someone reaches for it.
let stopped = still;
const samples = ["250 usd in eur", "time in tokyo", "call Petra tomorrow", "how long do you boil an egg?", "12 km", "wikipedia.org"];
input.addEventListener("focus", () => { if (!stopped) { stopped = true; input.value = ""; answer(""); } });
(async () => {
  const wait = ms => new Promise(r => setTimeout(r, ms));
  for (let s = 0; !stopped; s = (s + 1) % samples.length) {
    await wait(s === 0 ? 1400 : 2600);
    input.value = "";
    for (const c of samples[s]) { if (stopped) return; input.value += c; await wait(46); }
    if (!stopped) answer(input.value);
  }
})();

// The eclipse closes as the first screen goes by.
const moon = document.getElementById("moon");
const puller = document.getElementById("puller"), range = puller.querySelector("input");
const shot = document.getElementById("splitshot");
let pulled = false;
range.addEventListener("input", () => { pulled = true; puller.style.setProperty("--p", range.value + "%"); });
if (!still) {
  let queued = false;
  const frame = () => {
    queued = false;
    const y = scrollY, vh = innerHeight;
    moon.setAttribute("cx", 234 - Math.min(34, 34 * y / vh));
    if (!pulled) {
      const r = puller.getBoundingClientRect();
      const p = Math.max(0, Math.min(1, (vh * .8 - r.top) / (vh * .55)));
      puller.style.setProperty("--p", p * 100 + "%");
      range.value = p * 100;
    }
    const s = shot.getBoundingClientRect();
    if (s.bottom > 0 && s.top < vh) shot.style.transform = `translateY(${(s.top + s.height / 2 - vh / 2) * -.04}px)`;
  };
  addEventListener("scroll", () => { if (!queued) { queued = true; requestAnimationFrame(frame); } }, { passive: true });
  frame();
}
