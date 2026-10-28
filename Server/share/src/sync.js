// roko's own sync: to-dos, the shopping lists and links sent to roko, the same
// on the iPhone and the Mac (Raycast). Each device keeps the number of the last
// change it has seen and asks for what came after; the later edit of a thing wins.
//
//   POST   /api/sync/space   a new space           → { key }
//   DELETE /api/sync/space   it and all in it      (Authorization: Bearer <key>)
//   GET    /api/sync?since=N changes after N       → { seq, changes, more }
//   POST   /api/sync         { changes: [...] }    → { seq }
//
// A change is { kind, id, data, updated, deleted }: kind "todo", "shopping" or
// "link"; data the thing as JSON (what's in it is the apps' business); updated
// when the device changed it, in ms. The key is "<space>.<secret>"; only a hash
// of the secret is kept.

const KINDS = new Set(["todo", "shopping", "link"]);
const ITEM_ID = /^[A-Za-z0-9_-]{1,64}$/;
const SPACE_ID = /^[A-Za-z0-9]{10}$/;
const LIMITS = { body: 400_000, changes: 500, data: 4_000, records: 5_000, page: 500 };
/** New spaces one address can open in a day, on top of the per-minute limit. */
const DAILY_PER_ADDRESS = 20;

export async function handleSync(request, env, url, helpers) {
  const { json, randomID, randomToken, sha256 } = helpers;

  if (url.pathname === "/api/sync/space") {
    if (request.method === "POST") return await openSpace(request, env, helpers);
    if (request.method === "DELETE") {
      const space = await spaceFor(request, env, sha256);
      if (!space) return json({ error: "Not found" }, 404);
      await env.DB.batch([
        env.DB.prepare("DELETE FROM sync_records WHERE space = ?").bind(space),
        env.DB.prepare("DELETE FROM sync_spaces WHERE id = ?").bind(space),
      ]);
      return new Response(null, { status: 204 });
    }
    return json({ error: "Not allowed" }, 405);
  }

  const space = await spaceFor(request, env, sha256);
  if (!space) return json({ error: "That sync key isn't known. Copy it again from roko's Settings." }, 401);
  if (request.method === "GET") return await changesSince(space, url, env, json);
  if (request.method === "POST") return await write(space, request, env, json);
  return json({ error: "Not allowed" }, 405);

  async function openSpace(request, env) {
    const address = request.headers.get("cf-connecting-ip") ?? "local";
    if (env.SYNC_LIMIT && !(await env.SYNC_LIMIT.limit({ key: address })).success) {
      return json({ error: "Too many at once. Try again in a minute." }, 429);
    }
    const addressHash = await sha256(`${env.ADDRESS_SALT ?? ""}${address}`);
    const { count } = await env.DB.prepare("SELECT COUNT(*) AS count FROM sync_spaces WHERE address_hash = ? AND created > ?")
      .bind(addressHash, Date.now() - 86_400_000).first();
    if (count >= DAILY_PER_ADDRESS) return json({ error: "That's a lot for one day. Try again tomorrow." }, 429);
    const id = randomID();
    const secret = randomToken();
    await env.DB.prepare("INSERT INTO sync_spaces (id, key_hash, address_hash, created) VALUES (?, ?, ?, ?)")
      .bind(id, await sha256(secret), addressHash, Date.now()).run();
    return json({ key: `${id}.${secret}` }, 201);
  }
}

/** The space the request's key opens, or null. A wrong key and no space look the same. */
async function spaceFor(request, env, sha256) {
  const match = /^Bearer ([A-Za-z0-9]{10})\.([A-Za-z0-9_-]{20,100})$/.exec(request.headers.get("authorization") ?? "");
  if (!match || !SPACE_ID.test(match[1])) return null;
  const row = await env.DB.prepare("SELECT key_hash FROM sync_spaces WHERE id = ?").bind(match[1]).first();
  return row !== null && row.key_hash === (await sha256(match[2])) ? match[1] : null;
}

async function changesSince(space, url, env, json) {
  const since = Math.max(0, Number.parseInt(url.searchParams.get("since") ?? "0", 10) || 0);
  const [{ results }, head] = await env.DB.batch([
    env.DB.prepare("SELECT kind, id, data, updated, deleted, seq FROM sync_records WHERE space = ? AND seq > ? ORDER BY seq LIMIT ?")
      .bind(space, since, LIMITS.page + 1),
    env.DB.prepare("SELECT seq FROM sync_spaces WHERE id = ?").bind(space),
  ]);
  const more = results.length > LIMITS.page;
  const rows = results.slice(0, LIMITS.page);
  const changes = rows.map((row) => ({
    kind: row.kind, id: row.id, updated: row.updated, deleted: row.deleted === 1,
    data: row.data === null ? null : JSON.parse(row.data),
  }));
  // With more to come, the next page starts after the last one sent.
  const seq = more ? rows.at(-1).seq : head.results[0]?.seq ?? since;
  return json({ seq, changes, more });
}

async function write(space, request, env, json) {
  const body = await request.text();
  if (body.length > LIMITS.body) return json({ error: "Too much at once." }, 413);
  let input;
  try {
    input = JSON.parse(body);
  } catch {
    return json({ error: "That isn't a list of changes." }, 400);
  }
  if (!input || !Array.isArray(input.changes) || input.changes.length > LIMITS.changes) {
    return json({ error: "That isn't a list of changes." }, 400);
  }
  const changes = [];
  for (const change of input.changes) {
    const checked = readChange(change);
    if (checked.error) return json({ error: checked.error }, 400);
    changes.push(checked);
  }
  if (changes.length === 0) {
    const row = await env.DB.prepare("SELECT seq FROM sync_spaces WHERE id = ?").bind(space).first();
    return json({ seq: row?.seq ?? 0 });
  }
  const { count } = await env.DB.prepare("SELECT COUNT(*) AS count FROM sync_records WHERE space = ?").bind(space).first();
  if (count + changes.length > LIMITS.records) return json({ error: "That's more than roko keeps in sync." }, 413);

  // A block of change numbers, then each write takes one. A change older than
  // what's there is skipped by the WHERE, and its number simply goes unused.
  const { seq: last } = await env.DB.prepare("UPDATE sync_spaces SET seq = seq + ? WHERE id = ? RETURNING seq")
    .bind(changes.length, space).first();
  const first = last - changes.length + 1;
  await env.DB.batch(changes.map((change, index) => env.DB.prepare(
    `INSERT INTO sync_records (space, kind, id, data, updated, deleted, seq) VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (space, kind, id) DO UPDATE SET data = excluded.data, updated = excluded.updated,
       deleted = excluded.deleted, seq = excluded.seq
     WHERE excluded.updated >= sync_records.updated`,
  ).bind(space, change.kind, change.id, change.data, change.updated, change.deleted ? 1 : 0, first + index)));
  return json({ seq: last });
}

function readChange(change) {
  if (!change || typeof change !== "object") return { error: "That isn't a change." };
  const { kind, id, updated, deleted } = change;
  if (!KINDS.has(kind)) return { error: "roko doesn't sync that kind of thing." };
  if (typeof id !== "string" || !ITEM_ID.test(id)) return { error: "A change needs an id." };
  if (!Number.isSafeInteger(updated) || updated <= 0) return { error: "A change needs the time it was made." };
  if (deleted === true) return { kind, id, updated, deleted: true, data: null };
  if (!change.data || typeof change.data !== "object" || Array.isArray(change.data)) return { error: "A change needs what changed." };
  const data = JSON.stringify(change.data);
  if (data.length > LIMITS.data) return { error: "That one is too long to sync." };
  return { kind, id, updated, deleted: false, data };
}
