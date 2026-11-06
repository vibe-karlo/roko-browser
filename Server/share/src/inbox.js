// Newsletters in roko: a private address to subscribe with or forward to. Mail
// sent there waits here until the iPhone has fetched it, then it's deleted; what
// nobody fetches goes after 30 days. The address's owner is known only by a key.
//
//   POST   /api/inbox       a new box                 → { address, key }
//   DELETE /api/inbox       it and all in it          (Authorization: Bearer <key>)
//   GET    /api/inbox       mail waiting              → { mail: [...] }
//   DELETE /api/inbox/:id   fetched, so forget it
//
// Mail reaches the Worker through Cloudflare Email Routing (a catch-all rule on
// MAIL_DOMAIN sent to this Worker), as `email` in worker.js. The key is
// "<box>.<secret>"; only a hash of the secret is kept.

import PostalMime from "postal-mime";

const BOX_ID = /^[a-z0-9]{10}$/;
const MAIL_ID = /^[A-Za-z0-9]{10}$/;
const LIMITS = { mail: 4_000_000, html: 800_000, text: 200_000, subject: 300, waiting: 200, page: 20 };
const KEPT_FOR = 30 * 86_400_000;
/** New boxes one address can open in a day, on top of the per-minute limit. */
const DAILY_PER_ADDRESS = 5;

export async function handleInbox(request, env, url, helpers) {
  const { json, randomID, randomToken, sha256 } = helpers;
  if (!env.MAIL_DOMAIN) return json({ error: "Newsletters aren't set up on this server." }, 503);

  if (url.pathname === "/api/inbox" && request.method === "POST") return await openBox();

  const box = await boxFor(request);
  if (!box) return json({ error: "That inbox key isn't known." }, 401);

  if (url.pathname === "/api/inbox") {
    if (request.method === "GET") return await waiting(box);
    if (request.method === "DELETE") {
      await env.DB.batch([
        env.DB.prepare("DELETE FROM inbox_mail WHERE box = ?").bind(box),
        env.DB.prepare("DELETE FROM inbox_boxes WHERE id = ?").bind(box),
      ]);
      return new Response(null, { status: 204 });
    }
    return json({ error: "Not allowed" }, 405);
  }
  const one = /^\/api\/inbox\/([^/]+)$/.exec(url.pathname);
  if (one && request.method === "DELETE" && MAIL_ID.test(one[1])) {
    await env.DB.prepare("DELETE FROM inbox_mail WHERE id = ? AND box = ?").bind(one[1], box).run();
    return new Response(null, { status: 204 });
  }
  return json({ error: "Not found" }, 404);

  async function openBox() {
    const address = request.headers.get("cf-connecting-ip") ?? "local";
    if (env.SYNC_LIMIT && !(await env.SYNC_LIMIT.limit({ key: address })).success) {
      return json({ error: "Too many at once. Try again in a minute." }, 429);
    }
    const addressHash = await sha256(`${env.ADDRESS_SALT ?? ""}${address}`);
    const { count } = await env.DB.prepare("SELECT COUNT(*) AS count FROM inbox_boxes WHERE address_hash = ? AND created > ?")
      .bind(addressHash, Date.now() - 86_400_000).first();
    if (count >= DAILY_PER_ADDRESS) return json({ error: "That's a lot for one day. Try again tomorrow." }, 429);
    const id = randomID().toLowerCase();
    const secret = randomToken();
    await env.DB.prepare("INSERT INTO inbox_boxes (id, key_hash, address_hash, created) VALUES (?, ?, ?, ?)")
      .bind(id, await sha256(secret), addressHash, Date.now()).run();
    return json({ address: `${id}@${env.MAIL_DOMAIN}`, key: `${id}.${secret}` }, 201);
  }

  /** The box the request's key opens, or null. A wrong key and no box look the same. */
  async function boxFor(request) {
    const match = /^Bearer ([a-z0-9]{10})\.([A-Za-z0-9_-]{20,100})$/.exec(request.headers.get("authorization") ?? "");
    if (!match) return null;
    const row = await env.DB.prepare("SELECT key_hash FROM inbox_boxes WHERE id = ?").bind(match[1]).first();
    return row !== null && row.key_hash === (await sha256(match[2])) ? match[1] : null;
  }

  async function waiting(box) {
    const { results } = await env.DB.prepare(
      "SELECT id, sender, sender_name, subject, received, unsubscribe, html, text FROM inbox_mail WHERE box = ? ORDER BY received LIMIT ?",
    ).bind(box, LIMITS.page).all();
    return json({ mail: results });
  }
}

/** A mail arriving: kept for its box, turned away if nobody has that address. */
export async function receiveMail(message, env, randomID) {
  const local = (message.to ?? "").split("@")[0].toLowerCase();
  if (!BOX_ID.test(local)) return message.setReject("No such address");
  const box = await env.DB.prepare("SELECT id FROM inbox_boxes WHERE id = ?").bind(local).first();
  if (!box) return message.setReject("No such address");
  if (message.rawSize > LIMITS.mail) return message.setReject("Too large");

  // What nobody fetched in time goes, whoever's it was.
  await env.DB.prepare("DELETE FROM inbox_mail WHERE received < ?").bind(Date.now() - KEPT_FOR).run();
  const { count } = await env.DB.prepare("SELECT COUNT(*) AS count FROM inbox_mail WHERE box = ?").bind(local).first();
  if (count >= LIMITS.waiting) return message.setReject("Mailbox full");

  const raw = await new Response(message.raw).arrayBuffer();
  const mail = await PostalMime.parse(raw);
  const unsubscribe = /<(https:[^>]+)>/.exec(message.headers.get("list-unsubscribe") ?? "")?.[1] ?? null;
  await env.DB.prepare(
    "INSERT INTO inbox_mail (id, box, sender, sender_name, subject, received, unsubscribe, html, text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
  ).bind(
    randomID(), local, mail.from?.address ?? message.from, mail.from?.name || null,
    (mail.subject ?? "(no subject)").slice(0, LIMITS.subject), Date.now(), unsubscribe,
    mail.html?.slice(0, LIMITS.html) ?? null, mail.text?.slice(0, LIMITS.text) ?? null,
  ).run();
}
