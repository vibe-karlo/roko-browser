// roko's shared answers: the app posts a Browse for Me page here and gets a
// short link back; anyone with the link sees the answer as a plain web page.
//
//   POST   /api/share        create   → { id, url, token }
//   PUT    /api/share/:id    update   (Authorization: Bearer <token>)
//   DELETE /api/share/:id    unshare  (Authorization: Bearer <token>)
//   GET    /a/:id            the page
//   GET    /i/:host          a site's icon, proxied so readers' browsers only talk to us
//
// Answers live in D1. Only a hash of each edit token and of each sharer's IP
// address is kept: the token to prove an edit, the IP to cap how many pages
// one address can make in a day.

import { answerPage, FAVICON, homePage, letterIcon, notFoundPage, PICTURE_SCRIPT } from "./page.js";

/** The hash the security policy allows the page's one script by, worked out once. */
let pictureScriptHash;
async function scriptHash() {
  if (!pictureScriptHash) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(PICTURE_SCRIPT));
    pictureScriptHash = `'sha256-${btoa(String.fromCharCode(...new Uint8Array(digest)))}'`;
  }
  return pictureScriptHash;
}

const LIMITS = { body: 200_000, turns: 10, question: 500, answer: 20_000, sources: 12, images: 4, url: 2_000, title: 300 };
/** Pages one address can make in a day, on top of the per-minute limit. */
const DAILY_PER_ADDRESS = 100;
const ID = /^[A-Za-z0-9]{10}$/;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/api/share") {
        return request.method === "POST" ? await create(request, env, url) : json({ error: "Not allowed" }, 405);
      }
      const api = /^\/api\/share\/([^/]+)$/.exec(url.pathname);
      if (api) {
        if (!ID.test(api[1])) return json({ error: "Not found" }, 404);
        if (request.method === "PUT") return await update(api[1], request, env, url);
        if (request.method === "DELETE") return await remove(api[1], request, env);
        return json({ error: "Not allowed" }, 405);
      }
      if (request.method !== "GET" && request.method !== "HEAD") return json({ error: "Not allowed" }, 405);

      const page = /^\/a\/([^/]+)$/.exec(url.pathname);
      if (page) return ID.test(page[1]) ? await show(page[1], env, url) : html(notFoundPage(), 404, env, 60);
      if (url.pathname.startsWith("/i/")) return await siteIcon(url.pathname.slice(3), ctx);
      switch (url.pathname) {
        case "/": return html(homePage({ appURL: env.APP_URL }), 200, env, 3600);
        case "/favicon.svg":
        case "/favicon.ico":
          return new Response(FAVICON, { headers: { "content-type": "image/svg+xml", "cache-control": "public, max-age=86400" } });
        // Crawlers may read pages (link previews need to); whether search
        // engines may list them is the noindex header's business.
        case "/robots.txt": return new Response("User-agent: *\nAllow: /\n", { headers: { "content-type": "text/plain" } });
        default: return html(notFoundPage(), 404, env, 60);
      }
    } catch (error) {
      console.error(error);
      return json({ error: "Something went wrong. Try again in a moment." }, 500);
    }
  },
};

// MARK: API

async function create(request, env, url) {
  const address = request.headers.get("cf-connecting-ip") ?? "local";
  if (env.SHARE_LIMIT && !(await env.SHARE_LIMIT.limit({ key: address })).success) {
    return json({ error: "Too many shares at once. Try again in a minute." }, 429);
  }
  const addressHash = await sha256(`${env.ADDRESS_SALT ?? ""}${address}`);
  const { count } = await env.DB.prepare("SELECT COUNT(*) AS count FROM shares WHERE address_hash = ? AND created > ?")
    .bind(addressHash, Date.now() - 86_400_000).first();
  if (count >= DAILY_PER_ADDRESS) return json({ error: "That's a lot of shares for one day. Try again tomorrow." }, 429);

  const record = await readRecord(request);
  if (record.error) return json({ error: record.error }, 400);

  const id = randomID();
  const token = randomToken();
  const now = Date.now();
  await env.DB.prepare("INSERT INTO shares (id, token_hash, address_hash, created, updated, data) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(id, await sha256(token), addressHash, now, now, JSON.stringify(record)).run();
  return json({ id, url: pageURL(id, env, url), token }, 201);
}

async function update(id, request, env, url) {
  if (!(await authorized(id, request, env))) return json({ error: "Not found" }, 404);
  const record = await readRecord(request);
  if (record.error) return json({ error: record.error }, 400);
  await env.DB.prepare("UPDATE shares SET data = ?, updated = ? WHERE id = ?").bind(JSON.stringify(record), Date.now(), id).run();
  return json({ id, url: pageURL(id, env, url) });
}

async function remove(id, request, env) {
  if (!(await authorized(id, request, env))) return json({ error: "Not found" }, 404);
  await env.DB.prepare("DELETE FROM shares WHERE id = ?").bind(id).run();
  return new Response(null, { status: 204 });
}

/** The edit token matches. A wrong token and a missing page look the same. */
async function authorized(id, request, env) {
  const token = /^Bearer ([A-Za-z0-9_-]{20,100})$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (!token) return false;
  const row = await env.DB.prepare("SELECT token_hash FROM shares WHERE id = ?").bind(id).first();
  return row !== null && row.token_hash === (await sha256(token));
}

function pageURL(id, env, url) {
  return `${(env.PUBLIC_URL || url.origin).replace(/\/$/, "")}/a/${id}`;
}

/** The posted page, cut down to what the page shows and checked on the way. */
async function readRecord(request) {
  const body = await request.text();
  if (body.length > LIMITS.body) return { error: "That page is too long to share." };
  let input;
  try {
    input = JSON.parse(body);
  } catch {
    return { error: "That isn't a page roko can share." };
  }
  if (!input || !Array.isArray(input.turns)) return { error: "That isn't a page roko can share." };

  const turns = input.turns.slice(0, LIMITS.turns).map((turn) => ({
    question: text(turn?.question, LIMITS.question),
    answer: text(turn?.answer, LIMITS.answer, true),
    sources: (Array.isArray(turn?.sources) ? turn.sources : [])
      .map((source) => ({ url: web(source?.url), title: text(source?.title, LIMITS.title) }))
      .filter((source) => source.url)
      .slice(0, LIMITS.sources)
      .map((source) => ({ url: source.url, title: source.title || new URL(source.url).hostname.replace(/^www\./, "") })),
    // https only: the page is https, and a browser drops plain-http pictures on it.
    images: (Array.isArray(turn?.images) ? turn.images : []).map((image) => web(image, true)).filter(Boolean).slice(0, LIMITS.images),
  })).filter((turn) => turn.question && turn.answer);

  if (turns.length === 0) return { error: "There's no answer to share yet." };
  const lang = typeof input.lang === "string" && /^[a-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$/.test(input.lang) ? input.lang : "";
  return { lang, turns };
}

function text(value, limit, multiline = false) {
  if (typeof value !== "string") return "";
  // No control characters; line breaks only where the Markdown needs them.
  const cleaned = value.replace(multiline ? /[\u0000-\u0009\u000B-\u001F\u007F]/g : /[\u0000-\u001F\u007F]/g, " ").trim();
  return cleaned.slice(0, limit);
}

/** An http(s) address, or nothing. Too long is nothing too: cut short, it would break. */
function web(value, httpsOnly = false) {
  if (typeof value !== "string" || value.length > LIMITS.url) return null;
  try {
    const url = new URL(value);
    if (url.protocol === "https:" || (!httpsOnly && url.protocol === "http:")) return url.href;
  } catch {}
  return null;
}

// MARK: Pages

async function show(id, env, url) {
  const row = await env.DB.prepare("SELECT data, created, updated FROM shares WHERE id = ?").bind(id).first();
  if (!row) return html(notFoundPage(), 404, env, 60);
  const record = { ...JSON.parse(row.data), created: row.created, updated: row.updated };
  return html(answerPage(record, { url: pageURL(id, env, url), appURL: env.APP_URL || "/", reportEmail: env.REPORT_EMAIL }),
    200, env, 300, await scriptHash());
}

/** A site's icon from DuckDuckGo's icon service (Google's as a fallback), cached a week. */
async function siteIcon(rawHost, ctx) {
  const host = decodeURIComponent(rawHost).toLowerCase();
  if (!/^[a-z0-9.-]{1,253}$/.test(host)) return new Response(null, { status: 404 });
  const cache = caches.default;
  const key = new Request(`https://icons.roko.invalid/${host}`);
  const cached = await cache.match(key);
  if (cached) return cached;

  let response = null;
  for (const source of [`https://icons.duckduckgo.com/ip3/${host}.ico`, `https://www.google.com/s2/favicons?domain=${host}&sz=64`]) {
    try {
      const fetched = await fetch(source, { cf: { cacheTtl: 604800 } });
      // Both answer "no icon" with a placeholder, as a 404: only a 200 counts.
      if (fetched.ok && (fetched.headers.get("content-type") ?? "").startsWith("image/")) {
        response = new Response(fetched.body, { headers: { "content-type": fetched.headers.get("content-type") } });
        break;
      }
    } catch {}
  }
  response ??= new Response(letterIcon(host.replace(/^www\./, "")), { headers: { "content-type": "image/svg+xml" } });
  response.headers.set("cache-control", "public, max-age=604800");
  response.headers.set("x-content-type-options", "nosniff");
  ctx.waitUntil(cache.put(key, response.clone()));
  return response;
}

function html(body, status, env, maxAge, script = null) {
  const headers = {
    "content-type": "text/html; charset=utf-8",
    "cache-control": `public, max-age=${maxAge}`,
    // No scripts but the one named by its hash; pictures from anywhere over https, styles inline.
    "content-security-policy": `default-src 'none'; img-src 'self' https:; style-src 'unsafe-inline'; script-src ${script ?? "'none'"}; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
  };
  // Until it's switched on, search engines leave shared pages out.
  if (env.INDEXABLE !== "true") headers["x-robots-tag"] = "noindex";
  return new Response(body, { status, headers });
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });
}

// MARK: Identifiers

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/** Ten characters, about 59 bits: unguessable, short enough to read out. */
function randomID() {
  let id = "";
  while (id.length < 10) {
    for (const byte of crypto.getRandomValues(new Uint8Array(16))) {
      // 62 characters: skip the bytes that would favour some.
      if ((byte & 63) < 62 && id.length < 10) id += ALPHABET[byte & 63];
    }
  }
  return id;
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function sha256(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
