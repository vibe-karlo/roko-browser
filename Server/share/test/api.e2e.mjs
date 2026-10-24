// End to end against a running server: `npm run dev`, then
//     node test/api.e2e.mjs [http://127.0.0.1:8787]
import assert from "node:assert/strict";

const base = process.argv[2] ?? "http://127.0.0.1:8787";
const post = (body, init = {}) => fetch(`${base}/api/share`, {
  method: "POST", headers: { "content-type": "application/json", ...init.headers }, body: typeof body === "string" ? body : JSON.stringify(body),
});

const page = {
  lang: "en",
  turns: [{
    question: "When is Oktoberfest 2026?",
    answer: "# Oktoberfest 2026\n> From **19 September** to 4 October.\n## [date] When\n- **Start:** 19 September\n- **End:** 4 October",
    sources: [{ url: "https://www.munich.travel/en/oktoberfest", title: "Oktoberfest dates" }, { url: "javascript:alert(1)", title: "bad" }],
    images: ["https://upload.wikimedia.org/wikipedia/commons/a/a1/Oktoberfest.jpg", "http://insecure.example/x.jpg"],
  }],
};

let checks = 0;
const check = async (label, fn) => { await fn(); checks++; console.log(`✔ ${label}`); };

// Create.
const created = await post(page);
const share = await created.json();
await check("creates a page", () => {
  assert.equal(created.status, 201);
  assert.match(share.id, /^[A-Za-z0-9]{10}$/);
  assert.equal(share.url, `${base}/a/${share.id}`);
  assert.ok(share.token.length >= 40);
});

// View.
const viewed = await fetch(share.url);
const html = await viewed.text();
await check("serves the page", () => {
  assert.equal(viewed.status, 200);
  assert.match(html, /<h1 class="title">Oktoberfest 2026<\/h1>/);
  assert.match(html, /<strong>19 September<\/strong>/);
  assert.match(html, /Based on 1 page/);
  assert.match(html, /property="og:title" content="Oktoberfest 2026"/);
  assert.match(html, /property="og:image" content="https:\/\/upload\.wikimedia\.org/);
  assert.match(html, /Answered by <strong>roko<\/strong>/);
});
await check("drops bad links and plain-http pictures", () => {
  assert.doesNotMatch(html, /javascript:/);
  assert.doesNotMatch(html, /insecure\.example/);
});
await check("locks the page down", () => {
  assert.match(viewed.headers.get("content-security-policy"), /default-src 'none'/);
  assert.equal(viewed.headers.get("x-robots-tag"), "noindex");
  assert.equal(viewed.headers.get("referrer-policy"), "no-referrer");
});

// Update.
const updatedPage = { ...page, turns: [...page.turns, { question: "And in 2027?", answer: "> Probably mid-September.", sources: [], images: [] }] };
const wrongToken = await fetch(`${base}/api/share/${share.id}`, {
  method: "PUT", headers: { authorization: `Bearer ${"x".repeat(43)}` }, body: JSON.stringify(updatedPage),
});
await check("refuses an edit without the right token", () => assert.equal(wrongToken.status, 404));
const updated = await fetch(`${base}/api/share/${share.id}`, {
  method: "PUT", headers: { authorization: `Bearer ${share.token}` }, body: JSON.stringify(updatedPage),
});
await check("updates with the token, same link", async () => {
  assert.equal(updated.status, 200);
  assert.equal((await updated.json()).url, share.url);
});
await check("shows the follow-up", async () => assert.match(await (await fetch(share.url)).text(), /And in 2027\?/));

// Bad input.
await check("rejects junk", async () => {
  assert.equal((await post("not json")).status, 400);
  assert.equal((await post({ turns: [] })).status, 400);
  assert.equal((await post({ turns: [{ question: "q" }] })).status, 400);
  assert.equal((await post("x".repeat(250_000))).status, 400);
});
await check("unknown pages are a 404 page", async () => {
  assert.equal((await fetch(`${base}/a/AAAAAAAAAA`)).status, 404);
  assert.equal((await fetch(`${base}/a/<script>`)).status, 404);
});
await check("icons come back as pictures", async () => {
  const icon = await fetch(`${base}/i/www.munich.travel`);
  assert.equal(icon.status, 200);
  assert.match(icon.headers.get("content-type"), /^image\//);
  const letter = await fetch(`${base}/i/no-such-site.invalid`);
  assert.equal(letter.headers.get("content-type"), "image/svg+xml");
});

// Unshare.
const deleted = await fetch(`${base}/api/share/${share.id}`, { method: "DELETE", headers: { authorization: `Bearer ${share.token}` } });
await check("unshares", () => assert.equal(deleted.status, 204));
await check("gone after unsharing", async () => assert.equal((await fetch(share.url)).status, 404));

// The per-minute limit: ten pages a minute from one address.
let limited = false;
for (let i = 0; i < 12 && !limited; i++) limited = (await post(page)).status === 429;
await check("limits how fast one address can share", () => assert.ok(limited));

await new Promise((resolve) => setTimeout(resolve, 300));
console.log(`${checks} checks passed`);
