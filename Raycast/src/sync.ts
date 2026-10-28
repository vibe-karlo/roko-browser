// roko's sync, from the Mac: the same server and records as roko on the
// iPhone (Browser/Today/RokoSync.swift). Raycast reads the whole space when a
// command opens, then again every few seconds while it's open; a change is
// written straight away, with the time it was made, and the later change wins.
import { getPreferenceValues } from "@raycast/api";
import { randomUUID } from "node:crypto";

export type Kind = "todo" | "shopping" | "later" | "link";

export interface TodoData {
  title: string;
  /** "2026-10-28"; none is Someday. */
  day?: string | null;
  /** For the week ending on `day`. */
  week?: boolean;
  /** "15:30". */
  time?: string | null;
  done?: boolean;
  doneAt?: number | null;
  order?: number;
  created?: number;
}

export interface ShoppingData {
  title: string;
  /** Left out when added here: roko works it out on the iPhone. */
  aisle?: string;
  /** The list it's on: "grocery", "drugstore" or "pharmacy". */
  shop?: string;
  /** The list it was put on by hand; empty: where its aisle is bought. */
  pinned?: string;
  done?: boolean;
  doneAt?: number | null;
  order?: number;
  created?: number;
}

/** A page saved to Read Later. Its text stays on the iPhone, which reads it when a page saved here arrives. */
export interface LaterData {
  url: string;
  title: string;
  site?: string;
  /** Its share picture. */
  image?: string | null;
  saved?: number;
  /** When it was opened; none is still to read. */
  read?: number | null;
}

export interface LinkData {
  url: string;
  title?: string;
}

export interface Thing<T> {
  id: string;
  updated: number;
  data: T;
}

interface Change {
  kind: Kind;
  id: string;
  updated: number;
  deleted?: boolean;
  data?: object | null;
}

interface Preferences {
  key: string;
  server: string;
  language?: "en" | "hr";
}

const preferences = () => getPreferenceValues<Preferences>();

async function call(path: string, init: RequestInit = {}) {
  const { key, server } = preferences();
  const response = await fetch(`${server.replace(/\/$/, "")}${path}`, {
    ...init,
    headers: { "content-type": "application/json", authorization: `Bearer ${key.trim()}`, ...init.headers },
  });
  const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) {
    throw new Error(typeof body.error === "string" ? body.error : `roko's server answered ${response.status}.`);
  }
  return body;
}

/** Everything in the space now, by kind: deleted things left out. */
export async function readAll() {
  const things = {
    todo: new Map<string, Thing<TodoData>>(),
    shopping: new Map<string, Thing<ShoppingData>>(),
    later: new Map<string, Thing<LaterData>>(),
    link: new Map<string, Thing<LinkData>>(),
  };
  let since = 0;
  let more = true;
  while (more) {
    const page = await call(`/api/sync?since=${since}`);
    for (const change of (page.changes ?? []) as Change[]) {
      const map = things[change.kind] as Map<string, Thing<unknown>> | undefined;
      if (!map) continue;
      if (change.deleted || !change.data) map.delete(change.id);
      else map.set(change.id, { id: change.id, updated: change.updated, data: change.data });
    }
    since = page.seq as number;
    more = page.more === true;
  }
  return {
    todos: [...things.todo.values()],
    shopping: [...things.shopping.values()],
    later: [...things.later.values()],
    links: [...things.link.values()],
  };
}

export async function write(changes: Change[]) {
  if (changes.length > 0) await call("/api/sync", { method: "POST", body: JSON.stringify({ changes }) });
}

export const newID = () => randomUUID();
/** As roko on the iPhone writes a Read Later page's id (Swift's uuidString): spelled the same, it's the same page. */
export const laterID = () => randomUUID().toUpperCase();
export const now = () => Date.now();

export function put(kind: Kind, id: string, data: object): Change {
  return { kind, id, updated: now(), data };
}

export function remove(kind: Kind, id: string): Change {
  return { kind, id, updated: now(), deleted: true };
}

// MARK: Words

export const language = () => preferences().language ?? "en";

export const SHOPS = ["grocery", "drugstore", "pharmacy"] as const;
export type Shop = (typeof SHOPS)[number];

const shopNames: Record<Shop, [string, string]> = {
  grocery: ["Groceries", "Trgovina"],
  drugstore: ["Drugstore", "Drogerija"],
  pharmacy: ["Pharmacy", "Ljekarna"],
};

const aisleNames: Record<string, [string, string]> = {
  produce: ["Fruit and vegetables", "Voće i povrće"],
  bakery: ["Bread and bakery", "Kruh i pekara"],
  meat: ["Meat and fish", "Meso i riba"],
  dairy: ["Dairy and eggs", "Mliječni proizvodi i jaja"],
  frozen: ["Frozen", "Smrznuto"],
  pantry: ["Pantry", "Namirnice"],
  breakfast: ["Coffee, tea and breakfast", "Kava, čaj i doručak"],
  sweets: ["Sweets and snacks", "Slatkiši i grickalice"],
  drinks: ["Drinks", "Pića"],
  household: ["Household", "Kućanstvo"],
  personal: ["Personal care", "Osobna njega"],
  baby: ["Baby", "Za bebe"],
  pets: ["Pets", "Kućni ljubimci"],
  medicine: ["Medicines and health", "Lijekovi i zdravlje"],
  other: ["Other", "Ostalo"],
};

/** The walk through a shop, as roko orders its aisles. */
export const AISLE_ORDER = Object.keys(aisleNames);

export function shopName(shop: string) {
  const names = shopNames[shop as Shop] ?? shopNames.grocery;
  return language() === "hr" ? names[1] : names[0];
}

export function aisleName(aisle?: string) {
  if (!aisle) return language() === "hr" ? "Razvrstava se…" : "Sorting…";
  const names = aisleNames[aisle] ?? aisleNames.other;
  return language() === "hr" ? names[1] : names[0];
}

/** "milk, eggs and bread" is three; "mlijeko, jaja i kruh" too. */
export function splitItems(typed: string) {
  return typed
    .split(/,|;|\n|\s+(?:and|i)\s+/i)
    .map((piece) => piece.trim())
    .filter(Boolean)
    .map((piece) => piece.charAt(0).toLocaleUpperCase() + piece.slice(1));
}

/** How roko compares things to buy: "2x Mlijeko" and "mlijeko" are one. */
export function itemKey(title: string) {
  return title
    .toLocaleLowerCase()
    .replace(/^\d+\s*x\s*/, "")
    .replace(/\s+/g, " ")
    .trim();
}

/** Things to buy, written to the space; ones already on a list are left. */
export async function addShopping(titles: string[], listed: Thing<ShoppingData>[], shop?: Shop) {
  const open = new Set(listed.filter((thing) => !thing.data.done).map((thing) => itemKey(thing.data.title)));
  const fresh = titles.filter((title) => {
    const key = itemKey(title);
    if (!key || open.has(key)) return false;
    open.add(key);
    return true;
  });
  await write(fresh.map((title) => put("shopping", newID(), { title, pinned: shop ?? "", created: now() })));
  return { added: fresh, already: titles.length - fresh.length };
}
