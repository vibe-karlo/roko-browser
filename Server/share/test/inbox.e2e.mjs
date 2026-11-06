// End to end against a running server: `npm run dev`, then
//     node test/inbox.e2e.mjs [http://127.0.0.1:8787]
// A mail "arrives" through wrangler's local email route.
import assert from "node:assert/strict";

const base = process.argv[2] ?? "http://127.0.0.1:8787";
let checks = 0;
const check = async (label, fn) => { await fn(); checks++; console.log(`✔ ${label}`); };

const call = (path, { key, method = "GET" } = {}) => fetch(`${base}${path}`, {
  method, headers: key ? { authorization: `Bearer ${key}` } : {},
});
const deliver = (to, subject = "Issue 12: what happened") => fetch(
  `${base}/cdn-cgi/handler/email?from=${encodeURIComponent("hello@example-news.com")}&to=${encodeURIComponent(to)}`,
  {
    method: "POST",
    body: [
      "From: Example News <hello@example-news.com>", `To: ${to}`, `Subject: ${subject}`, "Date: Fri, 6 Nov 2026 08:00:00 +0000",
      "Message-ID: <1@example-news.com>", "List-Unsubscribe: <https://example-news.com/leave?u=1>, <mailto:leave@example-news.com>",
      "MIME-Version: 1.0", 'Content-Type: multipart/alternative; boundary="b"', "",
      "--b", "Content-Type: text/plain; charset=utf-8", "", "The plain story.",
      "--b", "Content-Type: text/html; charset=utf-8", "", "<p>The <b>real</b> story.</p>", "--b--", "",
    ].join("\r\n"),
  },
);

const opened = await call("/api/inbox", { method: "POST" });
const { address, key } = await opened.json();
await check("opens a box with an address and a key", () => {
  assert.equal(opened.status, 201);
  assert.match(address, /^[a-z0-9]{10}@/);
  assert.match(key, /^[a-z0-9]{10}\.[A-Za-z0-9_-]{40,}$/);
});

await check("refuses a wrong key", async () => {
  assert.equal((await call("/api/inbox", { key: `${key.split(".")[0]}.${"x".repeat(43)}` })).status, 401);
  assert.equal((await call("/api/inbox")).status, 401);
});

await check("starts empty", async () => {
  assert.deepEqual(await (await call("/api/inbox", { key })).json(), { mail: [] });
});

await deliver(address);
let mail;
await check("a mail sent there is waiting, read properly", async () => {
  ({ mail } = await (await call("/api/inbox", { key })).json());
  assert.equal(mail.length, 1);
  assert.equal(mail[0].subject, "Issue 12: what happened");
  assert.equal(mail[0].sender, "hello@example-news.com");
  assert.equal(mail[0].sender_name, "Example News");
  assert.equal(mail[0].unsubscribe, "https://example-news.com/leave?u=1");
  assert.match(mail[0].html, /real/);
  assert.match(mail[0].text, /plain story/);
});

await check("another address's box doesn't see it", async () => {
  const other = await (await call("/api/inbox", { method: "POST" })).json();
  assert.deepEqual(await (await call("/api/inbox", { key: other.key })).json(), { mail: [] });
  await call("/api/inbox", { key: other.key, method: "DELETE" });
});

await check("once fetched it's gone from the server", async () => {
  assert.equal((await call(`/api/inbox/${mail[0].id}`, { key, method: "DELETE" })).status, 204);
  assert.deepEqual(await (await call("/api/inbox", { key })).json(), { mail: [] });
});

await check("deleting the box stops its key", async () => {
  assert.equal((await call("/api/inbox", { key, method: "DELETE" })).status, 204);
  assert.equal((await call("/api/inbox", { key })).status, 401);
});

console.log(`\n${checks} checks passed`);
