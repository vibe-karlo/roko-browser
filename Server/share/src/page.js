// The shared page: a Browse for Me answer laid out as the app lays it out,
// in the app's palette, light or dark with the reader's system. Plain HTML,
// one inline stylesheet and one tiny script, so it's small and opens at once.

import { TOPIC_ICONS } from "./icons.js";
import { escapeHTML, inline, parseAnswer, plain } from "./markdown.js";

/** roko's mark: the Eclipse from the app icon (Scripts/make_alternate_icons.swift). */
const ECLIPSE_PATH = "M0 300A300 300 0 1 0 600 300A300 300 0 1 0 0 300ZM244 300A150 150 0 1 0 544 300A150 150 0 1 0 244 300Z";
const mark = (className) => `<svg class="${className}" viewBox="0 0 600 600" aria-hidden="true"><path fill-rule="evenodd" d="${ECLIPSE_PATH}"/></svg>`;

/** The page's one script: a picture that won't load is removed, as in the app,
 *  rather than left as a broken frame. The security policy allows it by its hash. */
export const PICTURE_SCRIPT = "for(const i of document.querySelectorAll('.pictures img')){const gone=()=>{const s=i.parentElement;i.remove();if(!s.children.length)s.remove()};if(i.complete&&!i.naturalWidth)gone();else i.addEventListener('error',gone)}";

export const FAVICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600"><style>path{fill:#0E0E0F}@media(prefers-color-scheme:dark){path{fill:#E7E7E4}}</style><path fill-rule="evenodd" d="${ECLIPSE_PATH}"/></svg>`;

// Theme.swift's tokens: graphite greys with no blue in them, one orange.
const CSS = `
:root{color-scheme:light dark;--canvas:#E6E6E3;--raised:#FCFCFB;--ink:#0E0E0F;--ink2:#5C5C59;--ink3:#737370;--accent:#D4570C;--edge:rgb(14 14 15/.08)}
@media(prefers-color-scheme:dark){:root{--canvas:#0E0E0F;--raised:#252527;--ink:#E7E7E4;--ink2:#8C8C88;--ink3:#7E7E7A;--accent:#FF7A38;--edge:rgb(231 231 228/.08)}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--canvas);color:var(--ink);font:17px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:640px;margin:0 auto;padding:26px 22px 0}
a{color:inherit}
.turn+.turn{margin-top:56px}
.question{margin:0;font-size:17px;font-weight:600;line-height:1.35;color:var(--ink2)}
.strip{display:flex;gap:8px;overflow-x:auto;scrollbar-width:none;margin:0 -22px;padding:0 22px;scroll-padding:0 22px}
.strip::-webkit-scrollbar{display:none}
.pictures{margin-top:28px}
.pictures img{flex:none;width:240px;height:160px;object-fit:cover;border-radius:18px;background:var(--raised)}
.based{display:flex;align-items:center;gap:10px;margin-top:28px;font-size:14px;color:var(--ink2)}
.based span{display:flex;padding-right:5px}
.based img{width:22px;height:22px;margin-right:-5px;padding:2px;border-radius:6px;background:var(--canvas)}
.sources{margin-top:10px}
.source{flex:none;width:164px;padding:9px 11px;border-radius:13px;background:var(--raised);box-shadow:inset 0 0 0 1px var(--edge);text-decoration:none}
.source strong{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden;min-height:2.6em;font-size:13px;font-weight:500;line-height:1.3}
.source small{display:flex;align-items:center;gap:5px;margin-top:6px;font-size:11px;color:var(--ink2);white-space:nowrap;overflow:hidden}
.source small img{width:12px;height:12px;border-radius:3px}
.answer{margin-top:28px}
.answer>*{margin:0}
.answer>*+*{margin-top:22px}
.title{font-size:22px;font-weight:600;line-height:1.25}
.lead{font-size:20px;line-height:1.4}
.section h3{display:flex;align-items:center;gap:8px;margin:0;font-size:17px;font-weight:600}
.section h3 svg{flex:none;width:18px;height:18px;fill:currentColor}
.section p,.section ul{margin:8px 0 0;padding:0;color:var(--ink2)}
.section li{list-style:none;position:relative;padding-left:14px}
.section li+li{margin-top:8px}
.section li::before{content:"\\00B7";position:absolute;left:2px;color:var(--ink3)}
strong{font-weight:600;color:var(--ink)}
code{font-size:.9em}
.answer a{color:var(--accent);text-decoration:none}
.signature{max-width:640px;margin:72px auto 0;padding:0 22px 40px;font-size:14px;color:var(--ink2)}
.signature .brand{display:inline-flex;align-items:center;gap:10px;font-size:17px;color:var(--ink);text-decoration:none}
.signature .brand strong{font-weight:700;letter-spacing:.01em}
.mark{flex:none;width:20px;height:20px;fill:currentColor}
.signature p{margin:6px 0 0}
.signature .meta{color:var(--ink3);font-size:12px}
.signature .meta a{color:inherit}
.alone{min-height:100vh;min-height:100svh;display:grid;place-content:center;justify-items:center;gap:14px;padding:22px;text-align:center}
.alone .mark{width:72px;height:72px;margin-bottom:14px}
.alone h1{margin:0;font-size:34px;font-weight:700;letter-spacing:.01em}
.alone p{margin:0;max-width:22em;color:var(--ink2);text-wrap:balance}
.alone .meta{font-size:14px;color:var(--ink3)}
.alone a{color:var(--accent);text-decoration:none}
`;

function document({ title, description = "", url = "", image = "", lang = "", body }) {
  const meta = [
    `<meta name="description" content="${escapeHTML(description)}">`,
    url && `<link rel="canonical" href="${escapeHTML(url)}">`,
    `<meta property="og:site_name" content="roko">`,
    `<meta property="og:type" content="article">`,
    `<meta property="og:title" content="${escapeHTML(title)}">`,
    `<meta property="og:description" content="${escapeHTML(description)}">`,
    url && `<meta property="og:url" content="${escapeHTML(url)}">`,
    image && `<meta property="og:image" content="${escapeHTML(image)}">`,
    `<meta name="twitter:card" content="${image ? "summary_large_image" : "summary"}">`,
  ].filter(Boolean).join("");
  return `<!doctype html><html${lang ? ` lang="${escapeHTML(lang)}"` : ""}><head><meta charset="utf-8">`
    + `<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">`
    + `<title>${escapeHTML(title)}</title>${meta}`
    + `<meta name="theme-color" media="(prefers-color-scheme: light)" content="#E6E6E3">`
    + `<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#0E0E0F">`
    + `<link rel="icon" href="/favicon.svg" type="image/svg+xml">`
    + `<style>${CSS}</style></head><body>${body}</body></html>`;
}

const host = (url) => new URL(url).hostname.replace(/^www\./, "");
const icon = (url) => `/i/${encodeURIComponent(host(url))}`;

function section(section) {
  let html = `<section class="section">`;
  if (section.heading) {
    html += `<h3><svg viewBox="0 0 256 256" aria-hidden="true">${TOPIC_ICONS[section.topic] ?? TOPIC_ICONS.idea}</svg>${inline(section.heading)}</h3>`;
  }
  // Runs of bullets become one list; other lines stay paragraphs.
  let list = [];
  const flush = () => {
    if (list.length) html += `<ul>${list.map((text) => `<li>${inline(text)}</li>`).join("")}</ul>`;
    list = [];
  };
  for (const line of section.lines) {
    if (line.bullet) list.push(line.text);
    else {
      flush();
      html += `<p>${inline(line.text)}</p>`;
    }
  }
  flush();
  return html + `</section>`;
}

function turn(turn, index) {
  const answer = parseAnswer(turn.answer);
  let html = `<article class="turn"><p class="question">${escapeHTML(turn.question)}</p>`;
  if (turn.images.length) {
    html += `<div class="strip pictures">${turn.images.map((src) =>
      `<img src="${escapeHTML(src)}" alt="" width="240" height="160" loading="${index === 0 ? "eager" : "lazy"}" referrerpolicy="no-referrer">`).join("")}</div>`;
  }
  if (turn.sources.length) {
    const count = turn.sources.length;
    html += `<div class="based"><span>${turn.sources.slice(0, 6).map((source) =>
      `<img src="${icon(source.url)}" alt="" width="22" height="22">`).join("")}</span>Based on ${count} ${count === 1 ? "page" : "pages"}</div>`;
    html += `<div class="strip sources">${turn.sources.map((source) =>
      `<a class="source" href="${escapeHTML(source.url)}" rel="nofollow ugc noopener"><strong>${escapeHTML(source.title)}</strong>`
      + `<small><img src="${icon(source.url)}" alt="" width="12" height="12">${escapeHTML(host(source.url))}</small></a>`).join("")}</div>`;
  }
  html += `<div class="answer">`;
  if (answer.title) html += index === 0 ? `<h1 class="title">${inline(answer.title)}</h1>` : `<h2 class="title">${inline(answer.title)}</h2>`;
  if (answer.lead.length) html += `<p class="lead">${inline(answer.lead.join(" "))}</p>`;
  html += answer.sections.map(section).join("");
  return html + `</div></article>`;
}

/** The page for a shared answer. */
export function answerPage(record, { url, appURL, reportEmail }) {
  const first = parseAnswer(record.turns[0].answer);
  const title = plain(first.title ?? record.turns[0].question);
  const description = plain(first.lead.join(" ")).slice(0, 200);
  const shared = new Date(record.updated ?? record.created)
    .toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
  const report = reportEmail
    ? ` · <a href="mailto:${escapeHTML(reportEmail)}?subject=${encodeURIComponent(`Report ${url}`)}">Report</a>` : "";
  const body = `<main>${record.turns.map(turn).join("")}</main><script>${PICTURE_SCRIPT}</script>`
    + `<footer class="signature"><a class="brand" href="${escapeHTML(appURL)}">${mark("mark")}<span>Answered by <strong>roko</strong></span></a>`
    + `<p>The iPhone browser that reads the web for you.</p>`
    + `<p class="meta">Shared ${escapeHTML(shared)}. Answers are written by AI from the pages above and can be wrong.${report}</p></footer>`;
  return document({ title, description, url, image: record.turns[0].images[0] ?? "", lang: record.lang, body });
}

/** The domain's own front page, until there's an App Store page to send people to. */
export function homePage({ appURL }) {
  const link = appURL && appURL !== "/"
    ? `<a href="${escapeHTML(appURL)}">Get roko</a>` : `In private testing.`;
  return document({
    title: "roko",
    description: "The iPhone browser that reads the web for you.",
    body: `<main class="alone">${mark("mark")}<h1>roko</h1><p>The iPhone browser that reads the web for you.</p><p class="meta">${link}</p></main>`,
  });
}

export function notFoundPage() {
  return document({
    title: "Not here · roko",
    body: `<main class="alone">${mark("mark")}<p>This page isn't here. It may have been unshared.</p><p class="meta"><a href="/">roko</a></p></main>`,
  });
}

/** A site with no icon of its own: its first letter, as in the app. */
export function letterIcon(hostname) {
  const letter = escapeHTML((hostname[0] ?? "?").toUpperCase());
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><style>text{fill:#737370;font:600 23px system-ui,-apple-system,sans-serif}@media(prefers-color-scheme:dark){text{fill:#7E7E7A}}</style><text x="16" y="16" text-anchor="middle" dominant-baseline="central">${letter}</text></svg>`;
}
