// Answers cookie pop-ups for roko with DuckDuckGo's Autoconsent (MPL-2.0),
// which knows the consent platforms by their rules (Consent-O-Matic's among
// them) and finds the rest by their buttons. It runs in its own content world,
// out of the page's reach; roko decides, per site, whether to reject or accept
// (ConsentHandler.swift), and accepts only where a site doesn't work without:
//
// - a wall: rejecting failed and the pop-up is still in the way;
// - a price on no: the pop-up's reject button is "Reject and Pay", or the only
//   other way past it is a subscription, also where no rule knows the pop-up;
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
const ACCEPT = /^(accept|accept all|accept cookies|i accept|allow|allow all|agree|i agree|ok|okay|got it|prihvati|prihvati sve|prihvaćam|prihvacam|slažem se|slazem se|akzeptieren|alle akzeptieren|accepter|tout accepter|accetta|accetta tutto|aceptar|aceptar todo|accepteren|přijmout|akceptuję)$/i;
const COOKIE_WORDS = /cookie|kolačić|kolacic|kolačiće|keks|galleta|biscott/i;

// A pop-up whose only no costs money ("Reject and Pay", "Rifiuta e abbonati", "Deny & surf
// ad-free"): rejecting means paying, so it's a wall, and pressing reject would only lead
// to the payment page. In any of the languages below, a word for no and a word for paying.
const SAY_NO = /\b(reject|refuse|decline|deny)\b|rifiut|rechaz|ablehn|refus|rejeit|recus|odbij|weiger|odrzu|odmít/i;
const payToRejectLabel = (words) => (SAY_NO.test(words) && WALL_PAY.test(words)) || /\bpay to (reject|refuse|decline)\b/i.test(words);
const shown = (el) => typeof el.checkVisibility !== 'function' || el.checkVisibility({ checkVisibilityCSS: true });
// Some walls ask twice (Il Messaggero: "press again to continue, 1/2"): while the same
// yes is still there, it's pressed again, a few times at most.
const pressUntilGone = (find, button) => {
    button.click();
    let presses = 1;
    const again = () => {
        const next = find();
        if (!next || presses++ >= 4) return;
        next.click();
        setTimeout(again, 700);
    };
    setTimeout(again, 700);
};
const buttonsOnPage = () => [...document.querySelectorAll('button, a, [role="button"], input[type="button"]')]
    .filter((b) => label(b).length <= 60 && shown(b));
const payToReject = () => buttonsOnPage().some((b) => payToRejectLabel(label(b)));
// Its accept button, pressed directly: a platform's rule can miss a site's
// own variant of the pop-up ("I Accept" beside "Reject and Pay").
const isYes = (words) => ACCEPT.test(words) || (WALL_YES.test(words) && !WALL_NOT_YES.test(words) && !WALL_PAY.test(words));
// The biggest first: a yes is a button, and the word "consent" in a line of text can be a
// link beside it (as.com's opens an explanation).
const area = (el) => { const r = el.getBoundingClientRect(); return r.width * r.height; };
const biggestFirst = (buttons) => [...buttons].sort((a, b) => area(b) - area(a));
const acceptBeside = () => biggestFirst(buttonsOnPage().filter((b) => isYes(label(b))))[0];

// A wall that no rule answers: a site's own (Marca's, Corriere's), or a platform's
// that Autoconsent leaves alone on purpose (Sourcepoint's with a subscribe button).
// Yes is free and no is a subscription, whatever the words, so roko says yes:
// a box pinned over the page, or a pop-up's whole frame, that talks about cookies
// or data and has both buttons. A newsletter's subscribe box has no accept button,
// and an "accept only necessary" isn't a yes.
const WALL_YES = /\b(accept|agree|consent|allow)\b|acept|aceit|accett|accept|akzept|zustimm|einverstanden|prihvać|prihvac|slažem|slazem|akkoord|zgadzam|souhlas/i;
const WALL_NOT_YES = /necess|essential|notwendig|erforderlich|nužn|nuzn|only|solo|nur\b|manag|setting|prefer|einstell|option|custom|personal|gestion|ajust|configur|detail|learn|more/i;
const WALL_PAY = /subscri|suscri|abonn|abbon|\babo\b|\bpay\b|\bpaga|\bpago\b|bezahl|kaufen|\bbuy\b|purchase|\bpur\b|pretplat|assin|ad[- ]?free|werbefrei|sans pub|sin (anuncios|publi)|senza pubbl|contentpass/i;
const WALL_WORDS = /cookie|kolačić|kolacic|consent|tracking|privacy|partner|personal|datos|daten|données|donnees|dati\b|podat|werbung|publicidad|pubblicit|publicité|adverts/i;
const WALL_BUTTONS = 'button, a, [role="button"], input[type="button"], input[type="submit"]';

// The big pinned boxes around a button, innermost first: a wall's buttons often sit in a
// small pinned footer of their own (Corriere's), inside the box that covers the page. On a
// small screen that footer counts as big too, so the size alone can't say which is the wall.
const pinnedBoxes = (el) => {
    const boxes = [];
    for (let node = el, depth = 0; node && node !== document.body && depth < 20; node = node.parentElement, depth++) {
        const position = getComputedStyle(node).position;
        if (position !== 'fixed' && position !== 'sticky') continue;
        const rect = node.getBoundingClientRect();
        if (rect.width >= window.innerWidth * 0.6 && rect.height >= window.innerHeight * 0.25) boxes.push(node);
    }
    return boxes;
};

// The yes button of such a wall, or null.
const paidWall = (mainFrame) => {
    const buttons = [...document.querySelectorAll(WALL_BUTTONS)].filter((b) => {
        const rect = b.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0 && label(b).length > 0 && label(b).length <= 60 && shown(b);
    });
    const pay = buttons.filter((b) => WALL_PAY.test(label(b)));
    if (!pay.length) return null;
    for (const yes of biggestFirst(buttons)) {
        const words = label(yes);
        if (!WALL_YES.test(words) || WALL_NOT_YES.test(words) || WALL_PAY.test(words)) continue;
        for (const box of mainFrame ? pinnedBoxes(yes) : [document.body]) {
            if (pay.some((b) => box.contains(b)) && WALL_WORDS.test((box.innerText || '').slice(0, 3000))) return yes;
        }
    }
    return null;
};

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
        // Autoconsent's bookkeeping, a "report" after every step and an "init"
        // before the rules are in: nothing in roko reads them but the -perf log.
        if ((message.type === 'report' || message.type === 'init') && !window.__rokoConsentReports) return;
        let reply = await post(message);
        if (message.type === 'popupFound' && reply && payToReject()) {
            if (reply.type === 'optOut') reply = await post({ type: 'rokoWall', cmp: message.cmp });
            const button = acceptBeside();
            if (button) {
                pressUntilGone(acceptBeside, button);
                accepted = true;
                countSaved(1);
                return;
            }
        }
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

    // A platform's pop-up no rule can see: index.hr's anti-adblock scrambles
    // ids and classes for everything but the page's own scripts, so Didomi's
    // #didomi-host reads "harzsgqw..." here. Its API still works: roko asks
    // the page whether the notice is up and answers it there.
    const watchForPlatformApi = () => {
        let handled = false;
        for (const delay of [2500, 5000, 9000, 14000]) {
            setTimeout(async () => {
                if (handled || consent.foundCmp) return;
                const reply = await post({ type: 'rokoPlatform' });
                if (!reply || !reply.answered) return;
                handled = true;
                countSaved(1);
                if (reply.accepted) accepted = true;
            }, delay);
        }
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

    // Also in frames: Sourcepoint's pop-up is a frame of its own.
    const watchForPaidWall = () => {
        for (const delay of [1000, 2500, 5000, 9000, 14000]) {
            setTimeout(async () => {
                if (accepted) return;
                const button = paidWall(mainFrame);
                if (!button) return;
                accepted = true;
                await post({ type: 'rokoWall', cmp: 'roko-paid-wall' });
                pressUntilGone(() => paidWall(mainFrame), button);
                countSaved(1);
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
            // Autoconsent's scan of the whole page's text for cookie wording,
            // on every pass: it only fills in a report nobody reads. The
            // pop-up heuristic below is a different thing and stays on.
            enableHeuristicDetection: false,
            // Pop-ups no rule knows: click reject, or a plain "OK" on a notice,
            // never "accept" on a guess.
            heuristicMode: 'tier1',
            // Each pass tries every rule, then waits half a second and a change
            // in the page. Ten passes still catch a pop-up drawn five seconds
            // after the page loaded; roko's own checks below run longer. A
            // frame has a handful of rules, and its pop-up is its whole content.
            detectRetries: mainFrame ? 10 : 5,
            isMainWorld: false,
            prehideTimeout: 2000,
            logs: { lifecycle: false, rulesteps: false, detectionsteps: false, evals: false, errors: false, messages: false, waits: false },
        },
        { autoconsent: [], compact: filterCompactRules(compactRules, { url: location.href, mainFrame }) },
    );
    watchForPaidWall();
    if (mainFrame) {
        watchForBlockedContent();
        watchForPlainBanner();
        watchForPlatformApi();
    }
}
