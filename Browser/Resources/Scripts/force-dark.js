// Force dark pages (ForceDark.swift). Only on pages it applies to; never loaded
// with the setting off. The page starts flipped, before anything is drawn, and
// the flip comes off before the first paint if the page turns out dark already.
(() => {
  const sheet = new CSSStyleSheet();
  // Screen only: paper stays white. Pictures and video flip back to their own
  // colours: the same two steps in the opposite order undo the page's flip.
  sheet.replaceSync(`@media screen {
    html { filter: invert(1) hue-rotate(180deg) !important; }
    img, video, canvas, iframe, embed, object { filter: hue-rotate(180deg) invert(1) !important; }
  }`);

  let flipped = false, paused = false, told = null;

  // How light a colour is, 0 to 1; null when it's see-through.
  const lightness = (color) => {
    const parts = color.match(/[\d.]+/g);
    if (!parts || (parts.length > 3 && +parts[3] < 0.5)) return null;
    return (0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]) / 255;
  };
  const background = (el) => getComputedStyle(el).backgroundColor;

  const isDark = () => {
    const body = document.body, root = document.documentElement;
    for (const el of [body, root]) {
      const value = lightness(background(el));
      if (value !== null) return value < 0.4;
    }
    // No background of its own: what most of the screen shows, at three heights.
    let dark = 0, light = 0;
    for (const height of [0.25, 0.5, 0.75]) {
      for (let el = document.elementFromPoint(innerWidth / 2, innerHeight * height); el; el = el.parentElement) {
        const value = lightness(background(el));
        if (value !== null) { value < 0.4 ? dark++ : light++; break; }
      }
    }
    if (dark || light) return dark > light;
    // No background anywhere: light text means a dark canvas.
    const text = lightness(getComputedStyle(body).color);
    return text !== null && text > 0.6;
  };

  const show = (flip) => {
    flipped = flip;
    const others = document.adoptedStyleSheets.filter((other) => other !== sheet);
    document.adoptedStyleSheets = flip && !paused ? [...others, sheet] : others;
  };

  // The app paints around the page to match: the status bar, the strip past its end.
  const tell = () => {
    const parts = [document.body, document.documentElement].map((el) => el && background(el))
      .find((color) => color && lightness(color) !== null);
    // No background of its own: white under the flip, the dark behind without it.
    const canvas = parts ? parts.match(/[\d.]+/g).slice(0, 3).join(",") : flipped ? "255,255,255" : "";
    const state = flipped + canvas;
    if (state === told) return;
    told = state;
    webkit.messageHandlers.rokoPage.postMessage({ kind: "dark", flipped, canvas });
  };

  const check = () => {
    if (!document.body) return;
    const dark = isDark();
    // A site that replaced the list of sheets took this one with it: back it goes.
    if (flipped === dark || (!dark && !document.adoptedStyleSheets.includes(sheet))) show(!dark);
    tell();
  };

  window.__rokoDark = (value) => { paused = value; show(flipped); };

  show(true);

  // Each frame until the document is parsed. Style is worked out for that frame
  // anyway, so this costs next to nothing, and it runs before the frame is drawn.
  let parsing = true;
  const frame = () => {
    check();
    if (parsing) requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
  document.addEventListener("DOMContentLoaded", () => { parsing = false; check(); }, { once: true });
  addEventListener("load", () => {
    check();
    // A page built by script may only now have its colours.
    setTimeout(check, 1000);
  }, { once: true });
})();
