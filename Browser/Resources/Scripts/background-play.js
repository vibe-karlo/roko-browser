// YouTube keeps playing, as sound, when roko leaves the screen. The page is
// told it is still in view, so its player doesn't pause itself; WebKit's own
// pause on leaving is undone by roko (BackgroundPlay), through __rokoPlayOn.
(() => {
    if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;

    const shown = { configurable: true, get: () => false };
    Object.defineProperty(Document.prototype, "hidden", shown);
    Object.defineProperty(Document.prototype, "webkitHidden", shown);
    Object.defineProperty(Document.prototype, "visibilityState", { configurable: true, get: () => "visible" });
    Object.defineProperty(Document.prototype, "webkitVisibilityState", { configurable: true, get: () => "visible" });
    for (const name of ["visibilitychange", "webkitvisibilitychange"]) {
        document.addEventListener(name, (event) => event.stopImmediatePropagation(), true);
    }

    // What was playing as roko left: only that plays on, so a video you had
    // paused stays paused.
    let playing = null;
    window.__rokoLeaving = () => {
        playing = [...document.querySelectorAll("video, audio")].find((m) => !m.paused && !m.ended) ?? null;
        return playing !== null;
    };
    window.__rokoPlayOn = () => {
        const media = playing;
        playing = null;
        if (media && media.paused && !media.ended) media.play().catch(() => {});
    };
})();
