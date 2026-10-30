// roko's own eyes on a page (PageWatch.swift), in a script world the page
// can't see: what you've typed into its forms, whether it's playing sound or
// video, and whether a sideways swipe started on something that scrolls
// sideways itself. Nothing here changes the page until roko asks.
(() => {
  if (window.__rokoPage) return;
  const post = (message) => {
    try { window.webkit.messageHandlers.rokoPage.postMessage(message); } catch (e) {}
  };

  // MARK: Forms

  // Never kept: passwords, card numbers, one-time codes, hidden fields, files.
  const skipTypes = new Set(["password", "hidden", "file", "submit", "button", "reset", "image", "search"]);
  const kept = (el) => {
    if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement)) return false;
    if (el.disabled || el.readOnly) return false;
    const type = (el.type || "").toLowerCase();
    if (skipTypes.has(type)) return false;
    const auto = (el.autocomplete || "").toLowerCase();
    if (auto.startsWith("cc-") || auto === "one-time-code" || auto.includes("password")) return false;
    // A search box isn't a form you'd be sorry to lose.
    if (el.closest("[role=search]") || /^(q|query|search|s)$/i.test(el.name || "")) return false;
    return true;
  };
  const fieldsOf = () => Array.from(document.querySelectorAll("input,textarea,select")).filter(kept);
  const keyOf = (el) => {
    const form = el.form ? Array.from(document.forms).indexOf(el.form) : -1;
    const own = el.id ? "#" + el.id : el.name ? "@" + el.name : "";
    if (own) return form + own;
    return form + "%" + fieldsOf().indexOf(el);
  };
  const valueOf = (el) => (el.type === "checkbox" || el.type === "radio") ? (el.checked ? "✓" : "") : el.value;

  let formTimer = 0;
  const noteForms = () => {
    clearTimeout(formTimer);
    formTimer = setTimeout(() => {
      const fields = {};
      let typed = 0;
      for (const el of fieldsOf()) {
        const value = valueOf(el);
        // Only what you changed: a field the page filled in itself isn't yours.
        if (!el.__rokoTouched || value === "") continue;
        fields[keyOf(el)] = value;
        if (el instanceof HTMLTextAreaElement || (el.type || "text") === "text" || el.type === "email") typed += value.length;
      }
      post({ kind: "form", fields: fields, typed: typed });
    }, 500);
  };
  const touched = (event) => {
    const el = event.target;
    if (!kept(el)) return;
    el.__rokoTouched = true;
    noteForms();
  };
  document.addEventListener("input", touched, true);
  document.addEventListener("change", touched, true);
  document.addEventListener("submit", () => post({ kind: "formSent" }), true);

  // MARK: Media

  let current = null;
  let lastTick = 0;
  // The largest picture the page gives for what's playing: its media session's
  // artwork, the video's poster, or the page's own share picture.
  const artworkOf = (el, meta) => {
    const art = meta && meta.artwork && meta.artwork.length
      ? [...meta.artwork].sort((a, b) => (parseInt(b.sizes) || 0) - (parseInt(a.sizes) || 0))[0].src : "";
    const og = document.querySelector('meta[property="og:image"]');
    const url = art || (el instanceof HTMLVideoElement && el.poster) || (og && og.content) || "";
    try { return url ? new URL(url, location.href).href : ""; } catch (e) { return ""; }
  };
  const report = (el) => {
    if (!el) return;
    current = el;
    lastTick = Date.now();
    const meta = navigator.mediaSession && navigator.mediaSession.metadata;
    post({
      kind: "media",
      playing: !el.paused && !el.ended,
      video: el instanceof HTMLVideoElement && el.videoWidth > 0,
      title: (meta && meta.title) || document.title || "",
      artist: (meta && meta.artist) || "",
      artwork: artworkOf(el, meta),
      time: el.currentTime || 0,
      duration: isFinite(el.duration) ? el.duration : 0,
      floating: el.webkitPresentationMode === "picture-in-picture" || document.pictureInPictureElement === el,
    });
  };
  for (const name of ["play", "playing", "pause", "ended", "seeked", "webkitpresentationmodechanged",
                      "enterpictureinpicture", "leavepictureinpicture"]) {
    document.addEventListener(name, (event) => {
      if (event.target instanceof HTMLMediaElement) report(event.target);
    }, true);
  }
  // Where it's got to, for the mini player's line: once a second at most.
  document.addEventListener("timeupdate", (event) => {
    if (event.target === current && Date.now() - lastTick > 1000) report(current);
  }, true);
  document.addEventListener("emptied", (event) => {
    if (event.target === current) { current = null; post({ kind: "mediaGone" }); }
  }, true);

  // The mini player's buttons.
  const media = () => current || document.querySelector("video, audio");

  // MARK: Swipe anywhere

  // Whether a sideways swipe from here belongs to the page: a carousel, a
  // map, a slider, a box that scrolls sideways, text being edited.
  let ownsSideways = false;
  document.addEventListener("touchstart", (event) => {
    ownsSideways = false;
    for (let el = event.target; el && el !== document.documentElement; el = el.parentElement) {
      if (!(el instanceof Element)) continue;
      const tag = el.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || tag === "CANVAS" || tag === "VIDEO"
          || tag === "IFRAME" || el.isContentEditable) { ownsSideways = true; break; }
      const style = getComputedStyle(el);
      if ((style.overflowX === "auto" || style.overflowX === "scroll") && el.scrollWidth > el.clientWidth + 2) { ownsSideways = true; break; }
      // Pages that drag things sideways themselves say so to the browser.
      const action = style.touchAction || "";
      if (action.includes("pan-y") && !action.includes("pan-x")) { ownsSideways = true; break; }
      if (action === "none") { ownsSideways = true; break; }
      if (/(carousel|swiper|slider|slick|splide|glide|flickity|gallery|scroller)/i.test(el.className && el.className.baseVal === undefined ? el.className : "")) { ownsSideways = true; break; }
    }
  }, { capture: true, passive: true });

  window.__rokoPage = {
    // Puts back what you'd typed, into fields that are empty again. Returns how many.
    restore(fields) {
      let count = 0;
      for (const el of fieldsOf()) {
        const value = fields[keyOf(el)];
        if (value === undefined) continue;
        if (el.type === "checkbox" || el.type === "radio") {
          if (el.checked !== (value !== "")) { el.checked = value !== ""; count++; }
        } else if (el.value === "") {
          const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), "value").set;
          setter.call(el, value);
          count++;
        } else continue;
        el.__rokoTouched = true;
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      }
      return count;
    },
    ownsSideways() { return ownsSideways; },
    toggle() {
      const el = media();
      if (!el) return false;
      if (el.paused) el.play(); else el.pause();
      return true;
    },
    pause() { const el = media(); if (el) el.pause(); },
    skip(seconds) {
      const el = media();
      if (!el) return;
      const end = isFinite(el.duration) ? el.duration : Infinity;
      el.currentTime = Math.max(0, Math.min(end, el.currentTime + seconds));
    },
    pictureInPicture() {
      const el = current instanceof HTMLVideoElement ? current : document.querySelector("video");
      if (!el) return false;
      if (el.webkitPresentationMode === "picture-in-picture") return true;
      if (el.webkitSupportsPresentationMode && el.webkitSupportsPresentationMode("picture-in-picture")) {
        el.webkitSetPresentationMode("picture-in-picture");
        return true;
      }
      if (el.requestPictureInPicture && document.pictureInPictureEnabled) {
        el.requestPictureInPicture().catch(() => {});
        return true;
      }
      return false;
    },
    inPictureInPicture() {
      const el = current instanceof HTMLVideoElement ? current : document.querySelector("video");
      return !!el && (el.webkitPresentationMode === "picture-in-picture" || document.pictureInPictureElement === el);
    },
    fullscreen() {
      const el = current instanceof HTMLVideoElement ? current : document.querySelector("video");
      if (!el || !el.webkitEnterFullscreen) return false;
      el.webkitEnterFullscreen();
      return true;
    },
  };
})();
