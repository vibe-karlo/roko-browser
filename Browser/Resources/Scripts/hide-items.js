// Hide Distracting Items: tap something on the page to mark it, tap it again
// to hide it. Injected only while the mode is on, into its own content world;
// nothing of it runs on a page otherwise. Each hidden thing is reported as a
// CSS selector, which roko keeps for the site and applies on every visit.
(() => {
  if (window.__rokoHideItems) { window.__rokoHideItems.start(); return; }
  const handler = window.webkit?.messageHandlers?.hideItems;

  const NEVER = new Set(["HTML", "BODY", "MAIN", "HEAD"]);
  // Names a site generates afresh (hashes, counters) don't survive a reload.
  // CSS-module hashes ("_6nuy7", "css-1x2y3z", "sc-bdVaJa") change with each deploy.
  const hashed = (name) => /^_|^(css|sc|jsx|emotion)-|\d{3,}/.test(name) || (/\d/.test(name) && /[a-z]/i.test(name) && !/[-_]/.test(name.slice(1)) && name.length <= 10);
  const stable = (name) => name.length < 40 && !hashed(name) && !/[a-z]+[A-Z][a-z]*\d/.test(name) && !/^(is|has)-|active|open|hover|focus|selected|visible/.test(name);
  const esc = (s) => CSS.escape(s);

  const part = (el) => {
    let s = el.tagName.toLowerCase();
    const classes = [...el.classList].filter(stable).slice(0, 2);
    for (const c of classes) s += "." + esc(c);
    const parent = el.parentElement;
    if (parent) {
      const same = [...parent.children].filter((c) => c.tagName === el.tagName && c.matches(s));
      if (same.length > 1) s += `:nth-of-type(${[...parent.children].filter((c) => c.tagName === el.tagName).indexOf(el) + 1})`;
    }
    return s;
  };

  // The shortest selector, anchored at the nearest stable id, that finds this
  // element and as little else as possible.
  const selectorFor = (el) => {
    if (el.id && stable(el.id)) return "#" + esc(el.id);
    const parts = [];
    for (let node = el; node && !NEVER.has(node.tagName); node = node.parentElement) {
      if (node !== el && node.id && stable(node.id)) { parts.unshift("#" + esc(node.id)); break; }
      parts.unshift(part(node));
      const s = parts.join(" > ");
      try { if (document.querySelectorAll(s).length === 1) return s; } catch (_) {}
      if (parts.length >= 6) break;
    }
    return parts.join(" > ");
  };

  let on = false, marked = null, box = null, style = null;
  const hidden = [];

  const place = () => {
    if (!marked || !box) return;
    const r = marked.getBoundingClientRect();
    Object.assign(box.style, { left: r.left + "px", top: r.top + "px", width: r.width + "px", height: r.height + "px" });
  };

  // The thing under the finger worth hiding: not a sliver of text, not the
  // whole page. Starts from the smallest box and widens until it's a real block.
  const pick = (x, y) => {
    let el = document.elementFromPoint(x, y);
    while (el && el.parentElement && !NEVER.has(el.parentElement.tagName)) {
      const r = el.getBoundingClientRect();
      if (r.width >= 40 && r.height >= 24) break;
      el = el.parentElement;
    }
    if (!el || NEVER.has(el.tagName) || el === box) return null;
    const r = el.getBoundingClientRect();
    if (r.width * r.height > innerWidth * innerHeight * 0.9) return null;
    return el;
  };

  const onClick = (event) => {
    if (!on) return;
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    const el = pick(event.clientX, event.clientY);
    if (!el) return;
    if (el === marked || marked?.contains(el)) return hide(marked);
    marked = el;
    box.style.opacity = "1";
    place();
  };

  // A wrapper holding nothing but this goes with it, or its padding stays
  // behind as an empty band.
  const outermost = (el) => {
    let box = el;
    while (box.parentElement && !NEVER.has(box.parentElement.tagName)) {
      const parent = box.parentElement;
      const others = [...parent.children].filter((c) => c !== box && c.offsetHeight > 0);
      if (others.length || parent.offsetHeight > box.offsetHeight + 60) break;
      box = parent;
    }
    return box;
  };

  const hide = (picked) => {
    const el = outermost(picked);
    const selector = selectorFor(el);
    // Fades and folds away, then stays gone through the site's own restyling.
    el.style.setProperty("transition", "opacity .18s ease-out, transform .18s ease-out", "important");
    el.style.setProperty("opacity", "0", "important");
    el.style.setProperty("transform", "scale(.97)", "important");
    box.style.opacity = "0";
    marked = null;
    setTimeout(() => {
      style.textContent += `:root ${selector}{display:none!important}\n`;
      el.style.removeProperty("transition");
    }, 180);
    hidden.push({ selector, el });
    handler?.postMessage({ type: "hidden", selector, count: hidden.length });
  };

  const stop = (event) => { if (on) { event.preventDefault(); event.stopPropagation(); } };

  const api = {
    start() {
      if (on) return;
      on = true;
      if (!style) { style = document.createElement("style"); (document.head || document.documentElement).appendChild(style); }
      if (!box) {
        box = document.createElement("div");
        box.setAttribute("aria-hidden", "true");
        box.style.cssText = "position:fixed;z-index:2147483647;pointer-events:none;box-sizing:border-box;border:2px solid #FF5B1F;background:rgba(255,91,31,.14);border-radius:6px;opacity:0;transition:left .12s,top .12s,width .12s,height .12s,opacity .12s;";
      }
      document.documentElement.appendChild(box);
      addEventListener("click", onClick, true);
      addEventListener("submit", stop, true);
      addEventListener("scroll", place, { passive: true, capture: true });
    },
    // Back: the last thing hidden shows again.
    undo() {
      const last = hidden.pop();
      if (!last) return hidden.length;
      style.textContent = hidden.map((h) => `:root ${h.selector}{display:none!important}`).join("\n") + "\n";
      for (const p of ["opacity", "transform", "transition"]) last.el.style.removeProperty(p);
      return hidden.length;
    },
    finish() {
      on = false;
      marked = null;
      box?.remove();
      removeEventListener("click", onClick, true);
      removeEventListener("submit", stop, true);
      removeEventListener("scroll", place, true);
      return hidden.splice(0).map((h) => h.selector);
    },
  };
  window.__rokoHideItems = api;
  api.start();
})();
