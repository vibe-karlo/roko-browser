// Answers cookie pop-ups for roko with DuckDuckGo's Autoconsent (MPL-2.0),
// which knows the consent platforms by their rules (Consent-O-Matic's among
// them) and finds the rest by their buttons. It runs in its own content world,
// out of the page's reach; roko decides, per site, whether to reject or accept
// (ConsentHandler.swift), and accepts only where a site doesn't work without:
//
// - a wall: rejecting failed and the pop-up is still in the way;
// - blocked content: the page shows a consent platform's "accept cookies to
//   see this video" placeholder, after roko rejected, or because the platform
//   itself was blocked (roko's cookie list blocks many of them) and never asked.
//
// Built into Browser/Resources/Scripts by Scripts/build_consent.sh.

// Where consent platforms put content that waits for consent: a video, a map,
// a post. Big enough to be content, not a stray icon.
const BLOCKED = [
    '.cookieconsent-optout-marketing', '.cookieconsent-optout-statistics', '.cookieconsent-optout-preferences', // Cookiebot
    '.uc-embedding-container', '.uc-embedding-wrapper', // Usercentrics
    '._brlbs-content-blocker', '.brlbs-cmpnt-content-blocker', // Borlabs
    '.cmplz-blocked-content-notice', '.cmplz-blocked-content-container', // Complianz
    '.cmplazypreviewmsg', '.cmplazypreviewiframe', // consentmanager
    '.cm-as-context-notice', // Klaro
    '.iubenda-cs-embed-blocker', // iubenda
    'iframe[data-cookieconsent][data-src]:not([src])', // Cookiebot, as an iframe
    'iframe[data-cmp-src]:not([src])', 'iframe[data-cookieblock-src]:not([src])',
    'iframe[class*="optanon-category"][data-src]:not([src])', // OneTrust
].join(',');

// A site's own cookie bar that no rule knows and whose wording Autoconsent's
// heuristic misses ("We use Google tools to measure visits. They set cookies
// only if you accept.", with Reject and Accept): a small fixed or sticky box
// that talks about cookies and has a button saying no. Words in English,
// Croatian and the larger European languages; whole button labels only, so a
// "Reject" somewhere in a sentence is never pressed.
const REJECT = /^(reject|reject all|reject cookies|decline|decline all|deny|deny all|refuse|refuse all|no,? thanks|only necessary|necessary only|only essential|essential only|use necessary cookies only|continue without accepting|odbij|odbij sve|odbaci|ne prihvaćam|ne prihvacam|samo nužni|samo nuzni|samo neophodni|ablehnen|alle ablehnen|nur notwendige|refuser|tout refuser|rifiuta|rifiuta tutto|rechazar|rechazar todo|weigeren|alles weigeren|odmítnout|odrzuć|odrzuc wszystko|avvisa|afvis|hylkää)$/i;
const ACCEPT = /^(accept|accept all|accept cookies|allow|allow all|agree|i agree|ok|okay|got it|prihvati|prihvati sve|prihvaćam|prihvacam|slažem se|slazem se|akzeptieren|alle akzeptieren|accepter|tout accepter|accetta|accetta tutto|aceptar|aceptar todo|accepteren|přijmout|akceptuję)$/i;
const COOKIE_WORDS = /cookie|kolačić|kolacic|kolačiće|keks|galleta|biscott/i;

const label = (el) => (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();

const pinned = (el) => {
    for (let node = el, depth = 0; node && node !== document.body && depth < 4; node = node.parentElement, depth++) {
        const position = getComputedStyle(node).position;
        if (position === 'fixed' || position === 'sticky') return true;
    }
    return false;
};

// The bar and its two buttons, or null. Cheap: only the page's top-level
// boxes and anything named like a cookie notice are looked at.
const plainBanner = () => {
    const candidates = document.querySelectorAll(
        'body > *, body > * > *, [role="dialog"], [role="alertdialog"], [role="region"], [aria-modal="true"], ' +
        '[aria-label*="cookie" i], [id*="cookie" i], [class*="cookie" i], [id*="consent" i], [class*="consent" i]');
    for (const box of candidates) {
        if (box === document.body || box.tagName === 'SCRIPT' || box.tagName === 'STYLE') continue;
        const rect = box.getBoundingClientRect();
        if (rect.width < 120 || rect.height < 40 || rect.height > window.innerHeight * 0.9) continue;
        if (typeof box.checkVisibility === 'function' && !box.checkVisibility({ checkVisibilityCSS: true })) continue;
        const text = (box.innerText || '').slice(0, 1500);
        if (!COOKIE_WORDS.test(text) && !COOKIE_WORDS.test(box.getAttribute('aria-label') || '')) continue;
        const buttons = [...box.querySelectorAll('button, a[role="button"], [role="button"], input[type="button"], input[type="submit"]')]
            .filter((b) => label(b).length <= 40);
        if (!buttons.length || buttons.length > 6) continue;
        const reject = buttons.find((b) => REJECT.test(label(b)));
        if (!reject || !pinned(box)) continue;
        return { box, reject, accept: buttons.find((b) => ACCEPT.test(label(b))) };
    }
    return null;
};

export function start(AutoConsent, filterCompactRules, compactRules) {
    if (window.__rokoConsent) return;
    window.__rokoConsent = true;
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.consent;
    if (!handler) return;
    const mainFrame = window.top === window;
    let consent = null;
    // Accepted on this page already: nothing left to unblock.
    let accepted = false;

    const post = async (message) => {
        try {
            return await handler.postMessage(message);
        } catch (_) {
            return null;
        }
    };

    // One pop-up answered: for Settings' count of what roko saved you.
    let counted = false;
    const countSaved = (clicks) => {
        if (counted) return;
        counted = true;
        post({ type: 'rokoSaved', clicks: Math.max(1, clicks || 0) });
    };

    const send = async (message) => {
        const reply = await post(message);
        if (message.type === 'optInResult' && message.result) accepted = true;
        if ((message.type === 'optOutResult' || message.type === 'optInResult') && message.result) {
            countSaved(consent && consent.state && consent.state.clicks);
        }
        if (message.type === 'optOutResult' && !message.result) {
            if (await stillInTheWay()) {
                // No way past it but accepting: roko accepts, if the site may.
                await answer(await post({ type: 'rokoWall', cmp: message.cmp }));
                return;
            }
        }
        await answer(reply);
    };

    const answer = async (reply) => {
        if (!reply) return;
        // A pop-up found by its buttons rather than by a rule: Autoconsent
        // can only reject those, so accepting means pressing its accept button.
        const cmp = consent.foundCmp;
        if (reply.type === 'optIn' && cmp && cmp.name.startsWith('HEURISTIC')) {
            const popup = cmp.popups && cmp.popups[0];
            const button = popup && popup.buttons.find((b) => b.regexClassification === 'accept');
            if (button) {
                button.element.click();
                accepted = true;
            }
            return;
        }
        await consent.receiveMessageCallback(reply);
    };

    const stillInTheWay = async () => {
        await new Promise((resolve) => setTimeout(resolve, 600));
        try {
            return !!(consent.foundCmp && (await consent.foundCmp.detectPopup()));
        } catch (_) {
            return false;
        }
    };

    const blockedContent = () => {
        let count = 0;
        for (const el of document.querySelectorAll(BLOCKED)) {
            const rect = el.getBoundingClientRect();
            if (rect.width >= 200 && rect.height >= 100) count++;
        }
        return count;
    };

    // When Autoconsent has found nothing: roko decides as for any pop-up,
    // and its button is pressed.
    const watchForPlainBanner = () => {
        let handled = false;
        for (const delay of [1500, 3500, 7000]) {
            setTimeout(async () => {
                if (handled || consent.foundCmp) return;
                const banner = plainBanner();
                if (!banner) return;
                handled = true;
                const reply = await post({ type: 'popupFound', cmp: 'roko-plain', url: location.href });
                const button = reply && reply.type === 'optIn' ? banner.accept : banner.reject;
                if (!button) return;
                button.click();
                countSaved(1);
                if (button === banner.accept) accepted = true;
            }, delay);
        }
    };

    const watchForBlockedContent = () => {
        let reported = false;
        for (const delay of [2000, 5000, 9000]) {
            setTimeout(async () => {
                if (reported || accepted) return;
                const count = blockedContent();
                if (!count) return;
                reported = true;
                const reply = await post({ type: 'rokoBlocked', count });
                if (!reply || reply.type !== 'rokoRecheck') return;
                // Accepted through the platform's own API: did the content come back?
                setTimeout(() => {
                    if (blockedContent()) post({ type: 'rokoStillBlocked' });
                }, 3000);
            }, delay);
        }
    };

    consent = new AutoConsent(send);
    consent.initialize(
        {
            enabled: true,
            // roko answers each pop-up itself: reject, or accept on sites that need it.
            autoAction: null,
            enablePrehide: true,
            enableCosmeticRules: true,
            enableGeneratedRules: true,
            enableHeuristicDetection: true,
            // Pop-ups no rule knows: click reject, or a plain "OK" on a notice,
            // never "accept" on a guess.
            heuristicMode: 'tier1',
            detectRetries: 20,
            isMainWorld: false,
            prehideTimeout: 2000,
            logs: { lifecycle: false, rulesteps: false, detectionsteps: false, evals: false, errors: false, messages: false, waits: false },
        },
        { autoconsent: [], compact: filterCompactRules(compactRules, { url: location.href, mainFrame }) },
    );
    if (mainFrame) {
        watchForBlockedContent();
        watchForPlainBanner();
    }
}
