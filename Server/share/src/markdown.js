// The Markdown roko's answers are written in, as the app lays it out
// (Browser/UI/MarkdownText.swift): a "# " title, the gist on "> " lines, then
// "## [topic] heading" sections of short lines or "- " bullets. Everything
// that reaches the page is escaped here; links must be http(s).

import { TOPIC_ICONS } from "./icons.js";

/** Splits an answer into the parts the page draws. */
export function parseAnswer(markdown) {
  const page = { title: null, lead: [], sections: [] };
  for (const raw of String(markdown).split("\n")) {
    const line = raw.trim();
    // Empty, a heading mark with no words yet, or a suggested follow-up
    // question ("?? "), which belongs to the app, not the page.
    if (!line || /^#+$/.test(line) || line === ">" || line === "?" || line.startsWith("??")) continue;
    if (line.startsWith("## ")) {
      const { topic, heading } = splitTopic(line.slice(3));
      page.sections.push({ topic: topic ?? guessTopic(heading), heading, lines: [] });
    } else if (line.startsWith("# ")) {
      page.title = line.slice(2);
    } else if (line.startsWith(">")) {
      page.lead.push(line.slice(1).trim());
    } else {
      const bullet = line.startsWith("- ") || line.startsWith("* ");
      const item = { bullet, text: bullet ? line.slice(2) : line };
      // Text before any heading reads as the gist.
      if (page.sections.length === 0) {
        if (!bullet) page.lead.push(item.text);
        else page.sections.push({ topic: null, heading: "", lines: [item] });
      } else {
        page.sections[page.sections.length - 1].lines.push(item);
      }
    }
  }
  return page;
}

/** "[privacy] Privacy first" → topic "privacy", heading "Privacy first". */
function splitTopic(raw) {
  let heading = raw;
  let topic = null;
  const tagged = /^\[([^\]]*)\]\s*/.exec(heading);
  if (tagged) {
    const tag = tagged[1].toLowerCase();
    topic = tag in TOPIC_ICONS ? tag : null;
    heading = heading.slice(tagged[0].length);
  }
  if (!topic && heading.trim().toLowerCase() in TOPIC_ICONS) return { topic: heading.trim().toLowerCase(), heading: "" };
  // Any emoji a model adds anyway.
  heading = heading.replace(/\p{Extended_Pictographic}️?/gu, "").trim();
  return { topic, heading };
}

/** When the model didn't tag a section, a fitting icon from its heading (as the app does). */
function guessTopic(heading) {
  const words = heading.toLowerCase();
  const hints = [
    ["weather", ["weather", "climate", "temperature", "rain", "snow", "sunshine"]],
    ["money", ["cost", "price", "pay", "budget", "cheap", "fee", "money", "cijen"]],
    ["time", ["when", "time", "hour", "how long", "schedule", "vrijeme"]],
    ["date", ["date", "year", "history", "season", "day"]],
    ["place", ["where", "location", "area", "district", "town", "city", "visit", "gdje"]],
    ["privacy", ["privacy", "security", "safe", "protect"]],
    ["speed", ["speed", "fast", "performance", "quick"]],
    ["warning", ["risk", "warning", "missing", "caution", "limit", "downside", "con"]],
    ["people", ["who", "people", "team", "family", "kids", "community"]],
    ["food", ["food", "eat", "drink", "restaurant", "coffee", "pizz", "dish", "menu", "cuisine", "hrana"]],
    ["travel", ["travel", "getting", "transport", "trip", "flight"]],
    ["compare", ["compare", "vs", "versus", "alternative", "option"]],
    ["star", ["best", "top", "highlight", "recommend"]],
    ["trend", ["trend", "growth", "market", "future"]],
    ["learn", ["learn", "background", "about", "what is", "overview"]],
    ["tools", ["how to", "setup", "use", "feature", "tool"]],
    ["news", ["news", "latest", "update", "announce"]],
  ];
  for (const [topic, keys] of hints) if (keys.some((key) => words.includes(key))) return topic;
  return "idea";
}

export function escapeHTML(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** Bold, italics, code and links inside a line, as safe HTML. */
export function inline(text) {
  let html = "";
  let last = 0;
  // Links first, on the raw text, so escaping can't mangle their addresses.
  for (const match of String(text).matchAll(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g)) {
    html += emphasis(escapeHTML(text.slice(last, match.index)));
    html += `<a href="${escapeHTML(match[2])}" rel="nofollow ugc noopener">${emphasis(escapeHTML(match[1]))}</a>`;
    last = match.index + match[0].length;
  }
  return html + emphasis(escapeHTML(text.slice(last)));
}

function emphasis(escaped) {
  return escaped
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*\w])\*(?!\s)([^*]+?)\*(?!\w)/g, "$1<em>$2</em>")
    .replace(/`([^`]+)`/g, "<code>$1</code>");
}

/** The words alone, for the link preview's description. */
export function plain(text) {
  return String(text)
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*`_]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}
