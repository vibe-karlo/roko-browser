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

### Changed
- Phosphor icons throughout.
- The page menu is a panel flush with the bottom edge.

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
