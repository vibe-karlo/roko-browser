// What a site's page needs changed before it runs, so its anti-adblock wall never
// comes up: BILD reads a flag, others wait on a timer or an ad script's variable.
// Only on sites with a rule (Scripts/build_scriptlets.py). Works alike to uBlock
// Origin's scriptlets, under the same names, so its rules (GPL-3.0) mean the same.
// ContentBlocker puts this site's calls in the loop at the end.
(() => {
  const pattern = (text) => {
    if (!text || text === "*") return /^/;
    const match = /^\/(.+)\/([gimsu]*)$/.exec(text);
    if (match) { try { return new RegExp(match[1], match[2]); } catch { return /^\b$/; } }
    return new RegExp(text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  };
  // "!x" as a needle means anything but x.
  const needle = (text = "") => {
    const not = text.startsWith("!");
    const re = pattern(not ? text.slice(1) : text);
    return (value) => re.test(value) !== not;
  };
  const CONSTANTS = {
    undefined: undefined, null: null, true: true, false: false, "": "", "''": "", NaN: NaN,
    noopFunc: () => {}, trueFunc: () => true, falseFunc: () => false, emptyStr: "",
    emptyArr: () => [], emptyObj: () => ({}), noopPromiseResolve: () => Promise.resolve(),
  };
  const constant = (raw) => {
    if (raw === "emptyArr" || raw === "[]") return [];
    if (raw === "emptyObj" || raw === "{}") return {};
    if (raw in CONSTANTS) return CONSTANTS[raw];
    if (/^-?\d+(\.\d+)?$/.test(raw)) return Number(raw);
    return undefined;
  };
  // Keeps a function looking like the browser's own to a page that checks.
  const wrap = (owner, name, apply) => {
    const original = owner[name];
    if (typeof original !== "function") return;
    owner[name] = new Proxy(original, { apply: (target, self, args) => apply(target, self, args) });
  };
  // Reaches a.b.c even when a doesn't exist yet: waits at each step for it to be set.
  const atChain = (owner, chain, onLast) => {
    const dot = chain.indexOf(".");
    if (dot < 0) return onLast(owner, chain);
    const head = chain.slice(0, dot), rest = chain.slice(dot + 1);
    let value;
    try { value = owner[head]; } catch { return; }
    if (value !== null && (typeof value === "object" || typeof value === "function")) return atChain(value, rest, onLast);
    try {
      Object.defineProperty(owner, head, {
        configurable: true, enumerable: true,
        get: () => value,
        set: (next) => {
          value = next;
          if (next !== null && (typeof next === "object" || typeof next === "function")) atChain(next, rest, onLast);
        },
      });
    } catch {}
  };
  const define = (owner, name, descriptor) => {
    try {
      const old = Object.getOwnPropertyDescriptor(owner, name);
      if (old && !old.configurable) return;
      Object.defineProperty(owner, name, { configurable: true, enumerable: true, ...descriptor });
    } catch {}
  };
  const thrower = (name) => () => { throw new ReferenceError(name); };
  const text = (handler) => { try { return typeof handler === "function" ? Function.prototype.toString.call(handler) : String(handler); } catch { return ""; } };
  const whenReady = (run) => {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run, { once: true });
    else run();
  };
  // Scripts the parser is reading: an observer sees each before it runs.
  const nodeText = (nodeName, change) => {
    const wanted = pattern(nodeName.startsWith("/") ? nodeName : `/^${nodeName.replace(/[^\w-]/g, "")}$/i`);
    const look = (node) => {
      if (node.nodeType !== 1 || !wanted.test(node.nodeName) || !node.firstChild) return;
      const before = node.textContent;
      const after = change(before);
      if (after !== before) node.textContent = after;
    };
    const observer = new MutationObserver((records) => {
      for (const record of records) {
        if (record.type === "characterData") { look(record.target.parentNode || {}); continue; }
        for (const node of record.addedNodes) (node.nodeType === 3 ? look(node.parentNode || {}) : look(node));
      }
    });
    observer.observe(document, { childList: true, subtree: true });
    addEventListener("load", () => setTimeout(() => observer.disconnect(), 3000), { once: true });
  };
  const everyChange = (run) => {
    whenReady(run);
    new MutationObserver(() => {
      if (run.queued) return;
      run.queued = true;
      setTimeout(() => { run.queued = false; run(); }, 100);
    }).observe(document, { childList: true, subtree: true, attributes: true });
  };
  const prune = (object, path) => {
    const walk = (value, keys) => {
      if (value === null || typeof value !== "object") return;
      const [key, ...rest] = keys;
      const names = key === "[]" || key === "*" || key === "{-}" || key === "[-]" ? Object.keys(value) : [key];
      for (const name of names) {
        if (!(name in value)) continue;
        if (rest.length) walk(value[name], rest);
        else if (Array.isArray(value)) value.splice(Number(name), 1);
        else delete value[name];
      }
    };
    walk(object, path.split(".").flatMap((key) => key.split(/(?=\[\])/)));
  };
  const has = (object, path) => {
    let value = object;
    for (const key of path.split(".")) {
      if (value === null || typeof value !== "object" || !(key in value)) return false;
      value = value[key];
    }
    return true;
  };
  const timerIf = (name, want = "", wantDelay = "") => {
    const matches = needle(want);
    const not = wantDelay.startsWith("!");
    const delay = parseInt(not ? wantDelay.slice(1) : wantDelay, 10);
    wrap(window, name, (target, self, args) => {
      const delayOK = isNaN(delay) || ((args[1] | 0) === delay) !== not;
      if (matches(text(args[0])) && delayOK) args = [() => {}, args[1]];
      return Reflect.apply(target, self, args);
    });
  };
  const boost = (name, want = "", wantDelay = "1000", factor = "0.05") => {
    const matches = needle(want === "*" ? "" : want);
    const delay = wantDelay === "*" ? NaN : parseInt(wantDelay, 10) || 1000;
    let by = parseFloat(factor); if (isNaN(by) || by < 0.001 || by > 50) by = 0.05;
    wrap(window, name, (target, self, args) => {
      if ((isNaN(delay) || (args[1] | 0) === delay) && matches(text(args[0]))) args = [args[0], (args[1] | 0) * by, ...args.slice(2)];
      return Reflect.apply(target, self, args);
    });
  };
  // "url:x method:POST", or a bare pattern against the address.
  const requestMatcher = (spec = "") => {
    const parts = spec.trim() ? spec.trim().split(/\s+/).map((part) => {
      const colon = part.indexOf(":");
      return colon > 0 && !part.startsWith("/") ? [part.slice(0, colon), needle(part.slice(colon + 1))] : ["url", needle(part)];
    }) : [];
    return (details) => parts.every(([key, test]) => test(String(details[key] ?? "")));
  };

  const SCRIPTS = {
    set: (chain, raw = "") => {
      const value = constant(raw);
      atChain(window, chain, (owner, name) => define(owner, name, { get: () => value, set: () => {} }));
    },
    aopr: (chain) => atChain(window, chain, (owner, name) => define(owner, name, { get: thrower(chain), set: () => {} })),
    aopw: (chain) => atChain(window, chain, (owner, name) => {
      let value; try { value = owner[name]; } catch {}
      define(owner, name, { get: () => value, set: thrower(chain) });
    }),
    acs: (chain, want = "", context = "") => {
      const matches = needle(want), inScript = needle(context);
      const check = () => {
        const script = document.currentScript;
        if (!(script instanceof HTMLScriptElement)) return;
        if (context && !inScript(script.src)) return;
        if (matches(script.textContent || script.src)) throw new ReferenceError(chain);
      };
      atChain(window, chain, (owner, name) => {
        let descriptor; try { descriptor = Object.getOwnPropertyDescriptor(owner, name); } catch {}
        let value = descriptor && "value" in descriptor ? descriptor.value : undefined;
        define(owner, name, {
          get() { check(); return descriptor && descriptor.get ? descriptor.get.call(this) : value; },
          set(next) { check(); if (descriptor && descriptor.set) descriptor.set.call(this, next); else value = next; },
        });
      });
    },
    aost: (chain, want = "") => {
      const matches = needle(want);
      const check = () => { if (matches(new Error().stack || "")) throw new ReferenceError(chain); };
      atChain(window, chain, (owner, name) => {
        let value; try { value = owner[name]; } catch {}
        define(owner, name, { get() { check(); return value; }, set(next) { check(); value = next; } });
      });
    },
    aeld: (type = "", want = "") => {
      const isType = needle(type), matches = needle(want);
      wrap(EventTarget.prototype, "addEventListener", (target, self, args) => {
        if (isType(String(args[0])) && matches(text(args[1]))) return;
        return Reflect.apply(target, self, args);
      });
    },
    nostif: (want, delay) => timerIf("setTimeout", want, delay),
    nosiif: (want, delay) => timerIf("setInterval", want, delay),
    "nano-stb": (want, delay, factor) => boost("setTimeout", want, delay, factor),
    "nano-sib": (want, delay, factor) => boost("setInterval", want, delay, factor),
    "no-fetch-if": (spec = "", body = "") => {
      if (spec === "") return;
      const matches = requestMatcher(spec);
      wrap(window, "fetch", (target, self, args) => {
        const input = args[0], options = args[1] || {};
        const details = { url: input instanceof Request ? input.url : String(input), method: options.method || (input instanceof Request ? input.method : "GET"), ...options };
        if (!matches(details)) return Reflect.apply(target, self, args);
        return Promise.resolve(new Response(body === "" || body.startsWith("length:") || body.startsWith("true:") ? "" : body, { status: 200, statusText: "OK" }));
      });
    },
    "no-xhr-if": (spec = "") => {
      if (spec === "") return;
      const matches = requestMatcher(spec);
      const faked = new WeakSet();
      wrap(XMLHttpRequest.prototype, "open", (target, self, args) => {
        if (matches({ method: args[0], url: String(args[1]) })) faked.add(self);
        return Reflect.apply(target, self, args);
      });
      wrap(XMLHttpRequest.prototype, "send", (target, self, args) => {
        if (!faked.has(self)) return Reflect.apply(target, self, args);
        for (const [name, value] of [["readyState", 4], ["status", 200], ["statusText", "OK"], ["response", ""], ["responseText", ""]]) {
          Object.defineProperty(self, name, { configurable: true, value });
        }
        setTimeout(() => {
          for (const event of ["readystatechange", "load", "loadend"]) self.dispatchEvent(new Event(event));
        }, 1);
      });
    },
    "noeval-if": (want = "") => {
      const matches = needle(want);
      wrap(window, "eval", (target, self, args) => (matches(String(args[0])) ? undefined : Reflect.apply(target, self, args)));
    },
    nowoif: (want = "") => {
      const not = want.startsWith("!");
      const re = pattern(not ? want.slice(1) : want);
      wrap(window, "open", (target, self, args) => {
        if (re.test(String(args[0] ?? "")) === not) return Reflect.apply(target, self, args);
        // A window that does nothing: a page that checks for its pop-up carries on.
        const quiet = new Proxy(() => {}, { get: (_, key) => (key === "closed" ? false : key === Symbol.toPrimitive ? () => "" : quiet), set: () => true, apply: () => quiet });
        return quiet;
      });
    },
    rmnt: (nodeName, want = "") => {
      const matches = needle(want);
      nodeText(nodeName, (body) => (matches(body) ? "" : body));
    },
    rpnt: (nodeName, want = "", replacement = "") => {
      const re = pattern(want);
      const global = new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
      nodeText(nodeName, (body) => body.replace(global, replacement));
    },
    ra: (names = "", selector = "[" + names + "]") => {
      const list = names.split(/\s*\|\s*/).filter(Boolean);
      everyChange(() => {
        try { for (const el of document.querySelectorAll(selector)) for (const name of list) el.removeAttribute(name); } catch {}
      });
    },
    rc: (names = "", selector = "") => {
      const list = names.split(/\s*\|\s*/).filter(Boolean);
      const where = selector || list.map((name) => "." + CSS.escape(name)).join(",");
      everyChange(() => {
        try { for (const el of document.querySelectorAll(where)) el.classList.remove(...list); } catch {}
      });
    },
    "json-prune": (paths = "", required = "") => {
      if (!paths) return;
      const list = paths.split(/\s+/), needs = required.split(/\s+/).filter(Boolean);
      wrap(JSON, "parse", (target, self, args) => {
        const result = Reflect.apply(target, self, args);
        if (result !== null && typeof result === "object" && needs.every((path) => has(result, path))) list.forEach((path) => prune(result, path));
        return result;
      });
    },
    // Only "JSON.parse, 0, repl:/x/y/, condition, z" and the like: one function, one text argument.
    "repl-arg": (chain = "", position = "0", replace = "", _ = "", condition = "") => {
      const match = /^repl:\/(.+)\/(.*)\/$/.exec(replace);
      const dot = chain.lastIndexOf(".");
      if (!match || dot < 0) return;
      const owner = chain.slice(0, dot).split(".").reduce((value, key) => (value ? value[key] : value), window);
      if (!owner) return;
      const re = new RegExp(match[1], "g"), index = parseInt(position, 10) || 0, wanted = pattern(condition);
      wrap(owner, chain.slice(dot + 1), (target, self, args) => {
        if (typeof args[index] === "string" && wanted.test(args[index])) args[index] = args[index].replace(re, match[2]);
        return Reflect.apply(target, self, args);
      });
    },
    ssi: (key = "", value = "") => {
      try {
        if (value === "$remove$") {
          const re = pattern(key);
          for (const name of Object.keys(localStorage)) if (key.startsWith("/") ? re.test(name) : name === key) localStorage.removeItem(name);
        } else if (["undefined", "false", "true", "null", "emptyArr", "emptyObj", "", "yes", "no", "on", "off", "accept", "accepted", "reject", "rejected", "allow", "deny"].includes(value) || /^\d+$/.test(value)) {
          localStorage.setItem(key, value === "emptyArr" ? "[]" : value === "emptyObj" ? "{}" : value);
        }
      } catch {}
    },
    scookie: (name = "", value = "", path = "/") => {
      if (!["true", "false", "yes", "no", "y", "n", "on", "off", "ok", "accept", "accepted", "reject", "rejected", "allow", "deny", "1", "0", ""].includes(value.toLowerCase()) && !/^\d+$/.test(value)) return;
      if (document.cookie.split("; ").some((pair) => pair.startsWith(name + "="))) return;
      document.cookie = `${encodeURIComponent(name)}=${encodeURIComponent(value)}; path=${path === "none" ? "/" : path}; max-age=31536000; SameSite=Lax`;
    },
    rcookie: (want = "") => {
      const re = pattern(want);
      const clear = () => {
        for (const pair of document.cookie.split(";")) {
          const name = pair.split("=")[0].trim();
          if (name && re.test(name)) document.cookie = `${name}=; path=/; max-age=0`;
        }
      };
      clear();
      addEventListener("beforeunload", clear);
    },
  };
  for (const [name, ...args] of __ROKO_CALLS__) {
    try { SCRIPTS[name](...args); } catch {}
  }
})();
