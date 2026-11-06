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
  let flushes = 0;

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
    flushes++;
    try {
      const reply = await handler.postMessage({ host: location.hostname, keys, first: isFirst });
      if (reply && reply.collapseAds) startCollapsing();
      if (!reply) return;
      if (reply.faded && reply.faded.length) fade(reply.faded);
      if (!reply.css) return;
      // A sheet of its own: added to one sheet, each reply had WebKit parse
      // everything received so far again.
      const style = document.createElement("style");
      style.textContent = reply.css;
      (document.head || document.documentElement).appendChild(style);
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
  const unlock = () => {
    for (const el of [document.documentElement, document.body]) {
      if (!el) continue;
      el.style.setProperty("overflow", "auto", "important");
      if (getComputedStyle(el).position === "fixed") el.style.setProperty("position", "static", "important");
    }
  };
  const coveredByWhatsLeft = () => {
    let el = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
    for (; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
      if (el.offsetHeight >= innerHeight * 0.5 && pinned(el)) return true;
    }
    return false;
  };
  const unlockIfNeeded = () => {
    const root = document.documentElement, body = document.body;
    if (!isLocked(root) && !isLocked(body)) return;
    // Lists hide plain page parts too (.social), and matching one of those proves nothing:
    // it must be the kind of thing that sits over a page. And a page locked behind something
    // still standing (a wall waiting for its answer) stays locked: Corriere, let go that
    // early, ran out of memory in a second.
    const hidOne = overlays.some((selector) => {
      try {
        for (const el of document.querySelectorAll(selector)) {
          const position = getComputedStyle(el).position;
          if (position === "fixed" || position === "sticky" || position === "absolute") return true;
        }
      } catch (_) {}
      return false;
    });
    if (hidOne && coveredByWhatsLeft()) return;
    if (hidOne) unlock();
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

  // A sticky slot's close button says what it closes ("Cerrar Publicidad"): still only a label.
  const CLOSE_AD = /(?:close|cerrar|schlie(?:ß|ss)en|fermer|chiudi|zatvori|sluiten)\s+(?:oglas|reklam\w*|advert\w*|ad|ads|anzeige|werbung|publicit[ée]|publicidad|pubblicit[àa]|annonce|reclame)\b/gi;
  const isLabelOnly = (text) => {
    if (!text) return true;
    if (text.length > 48) return false;
    const rest = text.replace(/\s+/g, " ").replace(CLOSE_AD, "").trim();
    return !rest || AD_LABEL.test(rest);
  };
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
  // What a reader could read. A slot often holds its own script or style, and those aren't
  // content: counting them kept Marca's and Welt's empty slots on the page. Past what a
  // label could be, the rest doesn't matter.
  const readable = (el) => {
    if (!el.querySelector("script,style,noscript")) return el.textContent.trim();
    let text = "";
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let node; (node = walker.nextNode()) && text.length <= 48;) {
      const parent = node.parentNode.nodeName;
      if (parent !== "SCRIPT" && parent !== "STYLE" && parent !== "NOSCRIPT") text += node.nodeValue;
    }
    return text.trim();
  };
  const isEmptyBox = (el) => isLabelOnly(readable(el)) && !hasRealMedia(el);
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
      // Only a box with an ad-like name, or a small one, can be a slot: the
      // page's big unnamed containers are left before their text is gathered.
      const name = el.id + " " + (typeof el.className === "string" ? el.className : "");
      const named = name.length > 1 && AD_NAME.test(name);
      if (!named && el.childElementCount > 4) continue;
      const text = readable(el);
      // A named slot may carry a site's lone mark (Welt's "-W-").
      if (!isLabelOnly(text) && !(named && /^\W*\w?\W*$/.test(text))) { settled.add(el); continue; }
      if (hasRealMedia(el)) continue;
      // An ad-like name, or (unnamed) an ad label shown as text or drawn by CSS.
      const isSlot = named || (height >= 50 && (text ? true : pseudoLabel(el)));
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
    foldAdStrips();
  };

  // A strip pinned along the bottom holding one picture and nothing else: an ad drawn by the
  // site's own scripts under a made-up name, on its own server (Focus's, where the same server
  // has its photos, so it can't be blocked). A real toolbar has words or links.
  const foldAdStrips = () => {
    for (const el of document.querySelectorAll(`body div:not([${MARK}]), body aside:not([${MARK}])`)) {
      const height = el.offsetHeight;
      if (height < 40 || height > 130 || el.offsetWidth < innerWidth * 0.9 || !el.querySelector("img")) continue;
      if (getComputedStyle(el).position !== "fixed") continue;
      if (el.getBoundingClientRect().bottom < innerHeight - 4 || (el.textContent || "").trim()) continue;
      if (el.querySelectorAll("img").length === 1 && !el.querySelector("a,button,input,video,canvas,svg,iframe")) el.setAttribute(MARK, "");
    }
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

  // MARK: Walls

  // A box over the page saying "disable your ad blocker": a site's own wall,
  // drawn by its own scripts under class names that change with every build,
  // which is how it slips past the lists (the New York Post's does). Known by
  // what it says and how it sits: a dialog, or pinned over the page, and big.
  // Hidden with its backdrop, and scrolling given back. An article about ad
  // blockers isn't pinned and runs longer than a notice, so it's left alone;
  // a cookie notice doesn't talk about blockers, and is answered, not hidden.
  const WALL_WORDS = /ad[\s-]?block|blokator\w* oglasa|blokiranj\w oglasa|werbeblock|bloqueur de pub|bloqueador de (anuncios|publicidad)|blocc\w (degli |della |di )?(annunci|pubblicit)|advertentieblok|blokad\w reklam|allow ads on|ads help keep|whitelist (us|this site|our site)|turn off your ad|disable your ad/i;
  const WALL = "data-roko-wall";
  let wallScans = 0, wallTimer = 0, wallStyle = null, pageLoaded = false;
  const pinned = (el) => {
    const s = getComputedStyle(el);
    return s.position === "fixed" || s.position === "sticky";
  };
  const wallCandidates = () => {
    const found = new Set();
    for (const el of document.querySelectorAll("dialog[open], [role=dialog], [role=alertdialog], [aria-modal=true], [class*=adblock i], [id*=adblock i]")) found.add(el);
    // Pinned boxes near the top of the tree: a wall is big, so its height is
    // checked first and the style of only the big ones is asked for.
    const tall = innerHeight * 0.2;
    for (const el of document.querySelectorAll("body > *, body > * > *, body > * > * > *")) {
      if (el.offsetHeight >= tall && pinned(el)) found.add(el);
    }
    return found;
  };
  const isWall = (el) => {
    const rect = el.getBoundingClientRect();
    if (rect.width < innerWidth * 0.5 || rect.height < innerHeight * 0.2) return false;
    if (typeof el.checkVisibility === "function" && !el.checkVisibility({ checkVisibilityCSS: true })) return false;
    const text = (el.innerText || "").trim();
    return text.length >= 20 && text.length <= 1500 && WALL_WORDS.test(text);
  };
  let hidAWall = false;
  const hideWall = (box) => {
    hidAWall = true;
    if (!wallStyle) {
      wallStyle = document.createElement("style");
      wallStyle.textContent = `[${WALL}]{display:none!important}`;
      (document.head || document.documentElement).appendChild(wallStyle);
    }
    box.setAttribute(WALL, "");
    // Its page may have gone with it: don't leave that blank a moment longer than needed.
    setTimeout(checkRefusal, 1500);
    // A backdrop drawn as a box of its own beside it: full-screen, pinned, wordless.
    for (const sibling of box.parentElement ? box.parentElement.children : []) {
      if (sibling === box || sibling.hasAttribute(WALL) || (sibling.innerText || "").trim()) continue;
      const r = sibling.getBoundingClientRect();
      if (r.width >= innerWidth * 0.9 && r.height >= innerHeight * 0.9 && pinned(sibling)) sibling.setAttribute(WALL, "");
    }
    unlock();
    const name = box.tagName.toLowerCase() + (box.id ? "#" + box.id : "")
      + (typeof box.className === "string" && box.className.trim() ? "." + box.className.trim().split(/\s+/).slice(0, 3).join(".") : "");
    handler.postMessage({ host: location.hostname, wall: name }).catch(() => {});
  };
  const wallPass = () => {
    wallTimer = 0;
    if (!document.body || wallScans++ > 40) return;
    for (const el of wallCandidates()) {
      if (el.hasAttribute(WALL) || el.closest(`[${WALL}]`)) continue;
      if (isWall(el)) hideWall(el);
    }
  };
  const scheduleWallPass = (delay) => {
    if (wallTimer) return;
    wallTimer = setTimeout(wallPass, delay);
  };
  // A wall comes once the page has seen its ads fail: a few looks after
  // load, then whenever the page adds to itself.
  const armWalls = () => {
    pageLoaded = true;
    for (const delay of [1200, 3000, 6000, 12000]) setTimeout(() => scheduleWallPass(0), delay);
  };
  if (document.readyState === "complete") armWalls();
  else addEventListener("load", armWalls, { once: true });

  // A page that keeps nothing once it has seen its ads fail: there's nothing to hide
  // a wall from. Known by its wall, a page about a screen tall, and next to no words or
  // pictures. Late, as an answered cookie wall can also leave a page empty until it
  // reloads. The app then tries the page with its ad scripts let through, then its ads.
  const refusesToShow = () => {
    const body = document.body;
    if (!body || (body.innerText || "").trim().length > 1200) return false;
    if (document.documentElement.scrollHeight > innerHeight * 1.6 || document.images.length > 12) return false;
    return hidAWall || document.querySelector('iframe[src*="adblock" i], iframe[id*="adblock" i], [class*="adblockwall" i], [id*="adblockwall" i]') !== null;
  };
  let reportedRefusal = false;
  const checkRefusal = () => {
    if (reportedRefusal || !refusesToShow()) return;
    reportedRefusal = true;
    handler.postMessage({ host: location.hostname, refused: true }).catch(() => {});
  };
  const armRefusal = () => { for (const delay of [8000, 13000, 19000]) setTimeout(checkRefusal, delay); };
  if (document.readyState === "complete") armRefusal();
  else addEventListener("load", armRefusal, { once: true });

  // MARK: Videos that loop by themselves

  // Blocking autoplay in WebKit stops video with sound, not muted video, so a page's
  // decorative loops all download at once however far down they are (CNN's: 6 MB before
  // you scroll). Each waits until it's near the screen, then plays as the page meant it to.
  // Only plain files: a player's stream (blob:) or a video with controls is left alone.
  const parked = new Map();
  const isLoop = (video) => video.tagName === "VIDEO" && !video.controls && (video.muted || video.defaultMuted)
    && (video.loop || video.autoplay) && /^https?:/.test(video.currentSrc || video.src);
  const nearScreen = (el) => {
    const rect = el.getBoundingClientRect();
    return rect.bottom > -innerHeight && rect.top < innerHeight * 2;
  };
  const wakeLoops = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting || !parked.has(entry.target)) continue;
      const video = entry.target, { src, sources } = parked.get(video);
      parked.delete(video);
      wakeLoops.unobserve(video);
      if (src) video.setAttribute("src", src);
      video.append(...sources);
      video.preload = "auto";
      video.load();
      video.play().catch(() => {});
    }
  }, { rootMargin: "100% 0px" });
  const parkLoop = ({ target: video }) => {
    if (parked.has(video) || !isLoop(video) || nearScreen(video)) return;
    parked.set(video, { src: video.getAttribute("src"), sources: [...video.querySelectorAll("source")] });
    video.removeAttribute("src");
    for (const source of parked.get(video).sources) source.remove();
    video.preload = "none";
    video.load();
    wakeLoops.observe(video);
  };
  document.addEventListener("loadstart", parkLoop, true);
  document.addEventListener("play", parkLoop, true);

  // The first request goes with the next frame, for the first paint. Later
  // ones wait for the page to settle a little: a page building itself asked
  // once a frame, and eleven requests in twelve brought nothing back.
  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    if (flushes === 0) requestAnimationFrame(flush);
    else setTimeout(flush, flushes < 4 ? 150 : 500);
  };

  if (document.documentElement) scan(document.documentElement);
  schedule();

  new MutationObserver((records) => {
    let added = false;
    for (const record of records) {
      if (record.type === "attributes") note(record.target);
      else for (const node of record.addedNodes) { scan(node); added = true; }
    }
    if (pending.length) schedule();
    if (added && pageLoaded) scheduleWallPass(800);
    // New slots appear as the page grows (infinite scroll, lazy sections).
    if (collapsing && lastPass) scheduleCollapse(0);
  }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "id"] });
})();
