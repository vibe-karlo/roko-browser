// End to end against a running server: `npm run dev`, then
//     node test/sync.e2e.mjs [http://127.0.0.1:8787]
import assert from "node:assert/strict";

const base = process.argv[2] ?? "http://127.0.0.1:8787";
let checks = 0;
const check = async (label, fn) => { await fn(); checks++; console.log(`✔ ${label}`); };

const call = (path, { key, method = "GET", body } = {}) => fetch(`${base}${path}`, {
  method,
  headers: { "content-type": "application/json", ...(key ? { authorization: `Bearer ${key}` } : {}) },
  body: body === undefined ? undefined : JSON.stringify(body),
});

// A space, as roko makes one.
const opened = await call("/api/sync/space", { method: "POST" });
const { key } = await opened.json();
await check("opens a space with a key", () => {
  assert.equal(opened.status, 201);
  assert.match(key, /^[A-Za-z0-9]{10}\.[A-Za-z0-9_-]{40,}$/);
});

await check("refuses a wrong key", async () => {
  const [space] = key.split(".");
  assert.equal((await call("/api/sync", { key: `${space}.${"x".repeat(43)}` })).status, 401);
  assert.equal((await call("/api/sync")).status, 401);
});

await check("starts empty", async () => {
  const body = await (await call("/api/sync?since=0", { key })).json();
  assert.deepEqual(body, { seq: 0, changes: [], more: false });
});

// The iPhone writes a to-do and two things to buy.
const t0 = Date.now();
const written = await call("/api/sync", { key, method: "POST", body: { changes: [
  { kind: "todo", id: "todo-1", updated: t0, data: { title: "Call the dentist", done: false } },
  { kind: "shopping", id: "milk", updated: t0, data: { title: "Mlijeko", aisle: "dairy", done: false } },
  { kind: "shopping", id: "eggs", updated: t0, data: { title: "Jaja", aisle: "dairy", done: false } },
] } });
const afterWrite = await written.json();
await check("takes changes and numbers them", () => {
  assert.equal(written.status, 200);
  assert.equal(afterWrite.seq, 3);
});

// The Mac, seeing everything so far.
const all = await (await call("/api/sync?since=0", { key })).json();
await check("hands everything to a device starting out", () => {
  assert.equal(all.seq, 3);
  assert.deepEqual(all.changes.map((c) => c.id), ["todo-1", "milk", "eggs"]);
  assert.equal(all.changes[1].data.title, "Mlijeko");
});

// The Mac ticks off the milk; the iPhone, offline, renamed it earlier.
await call("/api/sync", { key, method: "POST", body: { changes: [
  { kind: "shopping", id: "milk", updated: t0 + 2000, data: { title: "Mlijeko", aisle: "dairy", done: true } },
] } });
await call("/api/sync", { key, method: "POST", body: { changes: [
  { kind: "shopping", id: "milk", updated: t0 + 1000, data: { title: "Mlijeko 2L", aisle: "dairy", done: false } },
] } });
const later = await (await call("/api/sync?since=3", { key })).json();
await check("keeps the later edit when two devices change one thing", () => {
  assert.equal(later.changes.length, 1);
  assert.equal(later.changes[0].data.done, true);
  assert.equal(later.changes[0].data.title, "Mlijeko");
});

// A link sent from the Mac, opened and cleared by the iPhone.
await call("/api/sync", { key, method: "POST", body: { changes: [
  { kind: "link", id: "link-1", updated: t0 + 3000, data: { url: "https://www.bbc.com/news", title: "BBC News" } },
] } });
await call("/api/sync", { key, method: "POST", body: { changes: [
  { kind: "link", id: "link-1", updated: t0 + 4000, deleted: true },
] } });
const cleared = await (await call(`/api/sync?since=${later.seq}`, { key })).json();
await check("passes a deletion on as a marker", () => {
  const link = cleared.changes.find((c) => c.id === "link-1");
  assert.equal(link.deleted, true);
  assert.equal(link.data, null);
});

await check("turns away what it doesn't sync", async () => {
  for (const change of [
    { kind: "password", id: "x", updated: t0, data: {} },
    { kind: "todo", id: "has space", updated: t0, data: {} },
    { kind: "todo", id: "x", updated: "now", data: {} },
    { kind: "todo", id: "x", updated: t0, data: { title: "y".repeat(5000) } },
  ]) {
    assert.equal((await call("/api/sync", { key, method: "POST", body: { changes: [change] } })).status, 400);
  }
});

await check("keeps spaces apart", async () => {
  const other = (await (await call("/api/sync/space", { method: "POST" })).json()).key;
  const body = await (await call("/api/sync?since=0", { key: other })).json();
  assert.equal(body.changes.length, 0);
  await call("/api/sync/space", { key: other, method: "DELETE" });
});

await check("deletes a space and everything in it", async () => {
  assert.equal((await call("/api/sync/space", { key, method: "DELETE" })).status, 204);
  assert.equal((await call("/api/sync", { key })).status, 401);
});

console.log(`\n${checks} checks passed`);
