// On-demand element hiding. Rather than handing WebKit tens of thousands of
// selectors to test on every page, this lists the ids and classes the page
// actually uses and asks the app for just the hiding rules that could match.
// Runs in its own content world: the page can't see it or fake its messages.
(() => {
  if (window.__onDemandHiding) return;
  window.__onDemandHiding = true;

  const handler = window.webkit?.messageHandlers?.cosmetic;
  if (!handler) return;

  const seen = new Set();
  let pending = [];
  let scheduled = false;
  let first = true;
  let style = null;

  const note = (el) => {
    if (el.id) {
      const key = "#" + el.id;
      if (!seen.has(key)) { seen.add(key); pending.push(key); }
    }
    if (el.classList) {
      for (const name of el.classList) {
        const key = "." + name;
        if (!seen.has(key)) { seen.add(key); pending.push(key); }
      }
    }
  };

  const scan = (node) => {
    if (node.nodeType !== 1) return;
    note(node);
    for (const el of node.querySelectorAll("[id],[class]")) note(el);
  };

  const flush = async () => {
    scheduled = false;
    if (!pending.length && !first) return;
    const keys = pending;
    pending = [];
    const isFirst = first;
    first = false;
    try {
      const reply = await handler.postMessage({ host: location.hostname, keys, first: isFirst });
      if (reply && reply.collapseAds) startCollapsing();
      if (!reply) return;
      if (reply.faded && reply.faded.length) fade(reply.faded);
      if (!reply.css) return;
      if (!style) style = document.createElement("style");
      style.appendChild(document.createTextNode(reply.css + "\n"));
      if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
      unpushIfHidden();
      if (reply.overlays && reply.overlays.length) {
        overlays.push(...reply.overlays);
        unlockIfNeeded();
      }
    } catch (_) {}
  };

  // Cookie banners: invisible and untouchable at once, but still on the page
  // for a while, so roko's consent script can find each one and answer it
  // (a site whose banner is only hidden keeps asking, and keeps the page
  // locked). After that, whatever is left is removed for good.
  let fadeStyle = null, faded = [], fadeTimer = 0;
  const fadeRules = (block) => faded.map((s) => s + block).join("\n");
  const fade = (selectors) => {
    faded.push(...selectors);
    if (!fadeStyle) {
      fadeStyle = document.createElement("style");
      (document.head || document.documentElement).appendChild(fadeStyle);
    }
    fadeStyle.textContent = fadeRules("{opacity:0!important;pointer-events:none!important}");
    clearTimeout(fadeTimer);
    fadeTimer = setTimeout(() => { fadeStyle.textContent = fadeRules("{display:none!important}"); }, 10000);
  };

  // A hidden pop-up often leaves the page frozen: sites lock scrolling while
  // their overlay is up. If scrolling is locked and one of the overlays we hid
  // is actually on the page, give scrolling back.
  const overlays = [];
  const isLocked = (el) => {
    if (!el) return false;
    const s = getComputedStyle(el);
    return s.overflowY === "hidden" || s.overflow === "hidden" || s.position === "fixed";
  };
  const unlockIfNeeded = () => {
    const root = document.documentElement, body = document.body;
    if (!isLocked(root) && !isLocked(body)) return;
    const hidOne = overlays.some((selector) => {
      try { return document.querySelector(selector) !== null; } catch (_) { return false; }
    });
    if (!hidOne) return;
    for (const el of [root, body]) {
      if (!el) continue;
      el.style.setProperty("overflow", "auto", "important");
      if (getComputedStyle(el).position === "fixed") el.style.setProperty("position", "static", "important");
    }
  };
  // Sites often lock scrolling a moment after the pop-up would have appeared.
  for (const delay of [800, 2500, 6000]) setTimeout(() => overlays.length && unlockIfNeeded(), delay);

  // "Get our app" banners (smartbanner.js, on countless sites) push the page
  // down by their height and note the margin they replaced. Hidden, the banner
  // leaves that push behind as an empty band at the top: put the margin back.
  // A banner still showing (blocking off for the site) keeps its room.
  const PUSHED = "[data-smartbanner-original-margin-top],[data-smartbanner-original-top]";
  const unpushIfHidden = () => {
    if (!document.querySelector(PUSHED)) return;
    const banner = document.querySelector(".smartbanner, .js_smartbanner");
    if (banner && banner.offsetHeight > 0) return;
    for (const el of document.querySelectorAll("[data-smartbanner-original-margin-top]")) {
      el.style.marginTop = (parseFloat(el.getAttribute("data-smartbanner-original-margin-top")) || 0) + "px";
    }
    for (const el of document.querySelectorAll("[data-smartbanner-original-top]")) {
      el.style.top = (parseFloat(el.getAttribute("data-smartbanner-original-top")) || 0) + "px";
    }
  };
  // Only those two attributes are watched, so pages without the banner pay nothing.
  new MutationObserver(() => requestAnimationFrame(unpushIfHidden))
    .observe(document, { subtree: true, attributes: true,
      attributeFilter: ["data-smartbanner-original-margin-top", "data-smartbanner-original-top"] });

  // Empty ad boxes. With the ad blocked, many sites leave its box behind: a
  // grey rectangle saying "Oglas" or "Advertisement", or just a gap. Fold away
  // any box that looks like an ad slot and holds nothing a reader could want:
  // no text beyond such a label, no image, no video. A box with real content
  // is never touched, so a wrong guess can only remove emptiness.
  const AD_NAME = /(?:^|[-_ ])(?:ads?|adv|adverts?|advertisement|advertising|adslot|adunit|adbox|adzone|adholder|adwrap(?:per)?|adcontainer|dfp|gpt|banners?|billboard|leaderboard|skyscraper|oglas|reklam[a-z]*|werbung|anzeige)(?=$|[-_ \d])/i;
  const AD_LABEL = /^(?:oglas|reklama|advertisement|advertising|ads?|anzeige|werbung|publicit[ée]|publicidad|pubblicit[àa]|annonce|reclame|advertentie|sponsored ad)$/i;
  const NEVER = new Set(["HTML", "BODY", "MAIN", "ARTICLE", "HEADER", "NAV", "FOOTER", "FORM"]);
  const MARK = "data-roko-empty-ad";
  let collapsing = false, collapseTimer = 0, lastPass = 0;

  const isLabelOnly = (text) => !text || (text.length <= 24 && AD_LABEL.test(text.replace(/\s+/g, " ")));
  const pseudoLabel = (el) => {
    for (const which of ["::after", "::before"]) {
      const content = getComputedStyle(el, which).content;
      if (content && content !== "none" && content !== "normal" && content !== '""') {
        return AD_LABEL.test(content.replace(/^["']|["']$/g, "").trim());
      }
    }
    return false;
  };
  const hasRealMedia = (el) => {
    for (const media of el.querySelectorAll("img,picture,video,canvas")) {
      if (media.offsetWidth > 24 && media.offsetHeight > 24) return true;
      // An image still loading (lazy, below the fold) counts: it will have a size.
      if (media.tagName === "IMG" && !media.complete) return true;
    }
    return false;
  };
  const isEmptyBox = (el) => isLabelOnly(el.textContent.trim()) && !hasRealMedia(el);
  // Boxes holding real text: they never turn into empty ad slots, so later
  // passes skip them and stay cheap however long the page grows.
  const settled = new WeakSet();

  const collapsePass = () => {
    lastPass = Date.now();
    const body = document.body;
    if (!body) return;
    let shift = 0;
    for (const el of body.querySelectorAll(`div:not([${MARK}]),section:not([${MARK}]),aside:not([${MARK}]),ins:not([${MARK}]),figure:not([${MARK}])`)) {
      if (settled.has(el)) continue;
      const height = el.offsetHeight;
      if (height < 30 || height > 1200) continue;
      const text = el.textContent.trim();
      if (!isLabelOnly(text)) { settled.add(el); continue; }
      if (hasRealMedia(el)) continue;
      // An ad-like name, or (unnamed) an ad label shown as text or drawn by CSS.
      const name = el.id + " " + (typeof el.className === "string" ? el.className : "");
      const isSlot = (name.length > 1 && AD_NAME.test(name))
        || (el.childElementCount <= 4 && height >= 50 && (text ? true : pseudoLabel(el)));
      if (!isSlot) continue;
      // Take the box's empty wrappers with it, so no padded frame is left behind.
      let box = el;
      for (let i = 0; i < 3; i++) {
        const parent = box.parentElement;
        if (!parent || NEVER.has(parent.tagName) || parent.offsetHeight > box.offsetHeight + 150 || !isEmptyBox(parent)) break;
        box = parent;
      }
      if (NEVER.has(box.tagName)) continue;
      // Keep what's on screen still: a box removed above the reader would
      // otherwise pull the page up under them.
      const rect = box.getBoundingClientRect();
      if (rect.bottom <= 0) shift += rect.height;
      box.setAttribute(MARK, "");
    }
    if (shift) window.scrollBy(0, -shift);
  };

  // Never during a scroll: a pass reads layout, and the scroll needs every frame.
  let lastScroll = 0;
  addEventListener("scroll", () => { lastScroll = Date.now(); }, { passive: true, capture: true });

  const scheduleCollapse = (delay) => {
    if (!collapsing || collapseTimer) return;
    // At most one pass every two seconds, however busy the page is.
    const wait = Math.max(delay, 2000 - (Date.now() - lastPass));
    collapseTimer = setTimeout(() => {
      collapseTimer = 0;
      if (Date.now() - lastScroll < 250) return scheduleCollapse(300);
      if (window.requestIdleCallback) requestIdleCallback(collapsePass, { timeout: 500 });
      else collapsePass();
    }, wait);
  };

  const startCollapsing = () => {
    if (collapsing) return;
    collapsing = true;
    const css = document.createElement("style");
    css.textContent = `[${MARK}]{display:none!important}`;
    (document.head || document.documentElement).appendChild(css);
    // Give the page a moment to fill its slots (or fail to), then look.
    const begin = () => scheduleCollapse(1200);
    if (document.readyState === "complete") begin();
    else window.addEventListener("load", begin, { once: true });
  };

  // Batch everything noticed within a frame into one request.
  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(flush);
  };

  if (document.documentElement) scan(document.documentElement);
  schedule();

  new MutationObserver((records) => {
    for (const record of records) {
      if (record.type === "attributes") note(record.target);
      else for (const node of record.addedNodes) scan(node);
    }
    if (pending.length) schedule();
    // New slots appear as the page grows (infinite scroll, lazy sections).
    if (collapsing && lastPass) scheduleCollapse(0);
  }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "id"] });
})();
