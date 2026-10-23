// Answers cookie-consent dialogs with "reject" instead of only hiding them,
// so sites don't keep the page scroll-locked behind an invisible banner.
// Runs in an isolated content world: the page can't see or tamper with it.
(() => {
  if (window.__consentHandled) return;
  window.__consentHandled = true;

  // Reject / "necessary only" buttons of the common consent platforms.
  const rejectSelectors = [
    "#onetrust-reject-all-handler",                      // OneTrust
    "#CybotCookiebotDialogBodyButtonDecline",            // Cookiebot
    "#didomi-notice-disagree-button",                    // Didomi
    "button.sp_choice_type_REJECT_ALL",                  // Sourcepoint (iframe)
    ".fc-cta-do-not-consent",                            // Google Funding Choices
    "#cmpbntnotxt",                                      // consentmanager
    ".cky-btn-reject",                                   // CookieYes
    ".cmplz-deny",                                       // Complianz
    "#truste-consent-required",                          // TrustArc
    ".osano-cm-denyAll",                                 // Osano
    "#axeptio_btn_dismiss",                              // Axeptio
    "[data-cookiefirst-action='reject']",                // CookieFirst
    ".iubenda-cs-reject-btn",                            // iubenda
    "#tarteaucitronAllDenied2",                          // tarteaucitron
    ".cc-deny",                                          // Osano cookieconsent (legacy)
    "#W0wltc",                                           // Google search and YouTube (EU)
  ];

  // Usercentrics renders inside a shadow root.
  const shadowHosts = [["#usercentrics-root", "[data-testid='uc-deny-all-button']"]];

  const visible = (el) => el && el.getClientRects().length > 0;
  const clicked = new WeakSet();

  const tryReject = () => {
    for (const selector of rejectSelectors) {
      const button = document.querySelector(selector);
      if (visible(button) && !clicked.has(button)) {
        clicked.add(button);
        button.click();
        return true;
      }
    }
    for (const [hostSelector, selector] of shadowHosts) {
      const button = document.querySelector(hostSelector)?.shadowRoot?.querySelector(selector);
      if (visible(button) && !clicked.has(button)) {
        clicked.add(button);
        button.click();
        return true;
      }
    }
    return false;
  };

  if (tryReject()) return;

  // Banners usually appear a moment after load; watch briefly, then stop.
  let pending = false;
  const observer = new MutationObserver(() => {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      if (tryReject()) observer.disconnect();
    });
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  setTimeout(() => observer.disconnect(), 12000);
})();
