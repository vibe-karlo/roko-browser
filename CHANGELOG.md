# Changelog

All notable changes to roko. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Full-screen Summarize: the page shrinks into a card, live with a pinch, then the summary writes itself.
- Structured answers for Summarize and Browse for Me: a gist, then sections with topic icons.
- Browse for Me shows each site as it's read, with source cards, pictures and real site icons.
- Settings → App icon: ten alternates from the logo designs.
- Translate any page into English or Croatian, in place.
- Address suggestions show the real icon of 150 popular sites, bundled, with no network request.
- Haptics when a toast confirms an action, a tab is thrown away, or the bar swipes to the next tab.
- Browse for Me matches the question: a quick fact gets a short answer from three sources; a comparison, a "best" or a plan reads more sites and writes more.

### Changed
- Croatian pages are summarized by Claude Haiku when there's an API key; Apple's on-device model writes poor Croatian. English stays on the iPhone.
- Claude summaries use Haiku 5.5, and Browse for Me uses Haiku for quick questions and Sonnet 5.5 for the rest, instead of Opus.
- The address bar no longer lists open pages before you type; they show up when they match, marked "Already open".
- The address bar opens in one move: no dark overlay fading in over the page.
- Browse for Me's suggestion has a sparkle and says what it does: "Reads the web and answers".
- Phosphor icons throughout.
- The page menu is a panel flush with the bottom edge.
- Private mode is an eye that blinks shut, instead of glasses.
- Browse for Me is offered for questions of more than one word, not for a single word being typed.
- Text scrolling under the Summary and Browse for Me footers fades out instead of being cut off.

### Performance
- The first page after launch starts about 0.16 s sooner: it waits only for the request rules; the hiding indexes now decode in parallel.
- Tab saves are batched and no longer run on every page load; tab pictures compress off the main thread.
- Page loads skip resending unchanged blocker settings to WebKit.
- Site icons are no longer re-read from disk on every redraw.
- Scrolling no longer creates a timer per frame; the empty-ad-box check waits for scrolling to pause.

### Fixed
- Low memory: background tabs hibernate and tab pictures are released before iOS has to close roko.
- Old tab pictures and history older than 90 days are cleaned up after launch.
- Translation no longer loses its hook when a page in a translated tab navigates.
- The page no longer zooms out under the summary card while pinching.
- Summarize opens and closes seamlessly: the card and the page swap only where they match exactly.
- A site's header colour no longer shows at the bottom of the screen.
- The status bar stays readable over the address bar in light mode.
- The bar comes back after closing a summary, an answer or Reader Mode.
- Search suggestions no longer repeat exactly what you typed.
- On-device summaries no longer end mid-word when the model runs out of room; the unfinished point is left out.
- News about crimes or attacks is no longer refused by Apple's on-device safety filter as often.

## [0.1.0] - 2026-10-23

### Added
- WebKit browser with an Arc-style bar, tab carousel, pinned sites and private tabs.
- Blocking for ads, trackers, cookie banners and pop-ups, with a per-site switch.
- Empty ad boxes fold away on any site.
- Address bar calculator: maths, units, currencies, time zones and dates.
- Address suggestions from popular sites and your history.
- Summarize, Browse for Me and Reader Mode.
- Pull to refresh; status bar and page edges take the site's colours.
- Graphite theme with the Warp star app icon.

[Unreleased]: https://github.com/vibe-karlo/roko-browser/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/vibe-karlo/roko-browser/releases/tag/v0.1.0
