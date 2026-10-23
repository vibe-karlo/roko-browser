# Changelog

All notable changes to roko. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Full-screen Summarize: the page shrinks into a card, live with a pinch, then the summary writes itself.
- Structured answers for Summarize and Browse for Me: a gist, then sections with topic icons.
- Browse for Me shows each site as it's read, with source cards, pictures and real site icons.
- Settings → App icon: thirteen alternates from the logo designs, including three Eclipse marks (cream, on orange, orange).
- Translate any page into English or Croatian, in place.
- Address suggestions show the real icon of 150 popular sites, bundled, with no network request.
- Haptics when a toast confirms an action, a tab is thrown away, or the bar swipes to the next tab.
- Settings → Use Claude: turn Claude off without deleting the API key; Apple's models then do everything.
- Browse for Me suggests two or three follow-up questions under the answer when they'd help. Asking one adds a new section to the same page, answered with the earlier answers as context.
- Tap a question in Browse for Me to reword it; that section and the ones after it are asked again.
- An Answer / Google switch flips the Browse for Me page to the search results and back, from the start, losing neither. Closing the page stops any answer still being written.
- roko's orange light: while Browse for Me or Summarize works, a warm light rises from the bottom edge as pages are read, in one continuous motion, and sinks back into the edge when the answer starts.
- Browse for Me's answer arrives in order: the question shrinks to its heading, then pictures, sources and text ease in one after another.
- Browse for Me matches the question: a quick fact gets a short answer from three sources; a comparison, a "best" or a plan reads more sites and writes more.
- Answers written by Claude show pictures too, from the pages its searches found, fetched alongside while it works.
- A weather topic, with a sun, for answer sections about weather and seasons.

### Changed
- Croatian pages are summarized by Claude Haiku when there's an API key; Apple's on-device model writes poor Croatian. English stays on the iPhone.
- Claude summaries use Haiku 5.5, and Browse for Me uses Haiku for quick and ordinary questions and Sonnet 5.5 for deep ones, instead of Opus.
- Browse for Me always searches the web before answering, so every answer has sources.
- The address bar no longer lists open pages before you type; they show up when they match, marked "Already open".
- The address bar opens in one move: no dark overlay fading in over the page.
- Browse for Me is full screen, like Summarize; pull down at the top to close. When the answer arrives, the reading list's site icons fly into its row of sources.
- Browse for Me shows bigger pictures above more compact source cards.
- Text scrolling up in Summarize and Browse for Me fades under the status bar instead of running into the clock.
- Browse for Me's suggestion has a sparkle and says what it does: "Reads the web and answers".
- A question, comparison or decision puts Browse for Me first, so Return answers it; keywords, sites, weather and logins still search first.
- Phosphor icons throughout.
- The page menu is a panel flush with the bottom edge.
- Private mode is an eye that blinks shut, instead of glasses.
- Browse for Me is offered for questions of more than one word, not for a single word being typed.
- Text scrolling under the Summary and Browse for Me footers fades out instead of being cut off.
- The Eclipse icons use the app's own colours: its dark canvas, light ink and orange.
- In light mode roko's light warms toward amber at its edge, so it reads as sunlight, not a pink wash.
- Apple's models answer from what the sources say, instead of listing what they leave out; short answers give the facts in full sentences.
- A follow-up's section comes up to the top of the screen while it's worked on, instead of its reading list running under the footer.
- Rewording a question wraps over lines instead of scrolling sideways.

### Performance
- The first page after launch starts about 0.16 s sooner: it waits only for the request rules; the hiding indexes now decode in parallel.
- Tab saves are batched and no longer run on every page load; tab pictures compress off the main thread.
- Page loads skip resending unchanged blocker settings to WebKit.
- Site icons are no longer re-read from disk on every redraw.
- Scrolling no longer creates a timer per frame; the empty-ad-box check waits for scrolling to pause.
- Browse for Me is two to three times faster with Claude (measured on an iPhone): a deep question 48 s to 20 s, at about half the tokens; an ordinary one 29 s to 8 to 13 s, on Haiku, with the answer streaming in from about 6 s. Sonnet uses the basic search tool instead of the one that filters results by running code, searches less, and thinks at medium effort.

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
- The calculator reads currency symbols after the amount and decimal commas ("25$ in €", "12,50 € u kn"), plus Croatian currency names ("50 funti u eurima").
- Browse for Me no longer shows Claude thinking aloud between searches as the answer.
- Browse for Me counts the pages the answer is based on, not every search hit ("Read 39 pages").
- Source icons no longer show a grey arrow placeholder for sites without an icon.
- The on-device Browse for Me answers a Croatian question in Croatian.
- News about crimes or attacks is no longer refused by Apple's on-device safety filter as often.
- Summarize: "Writing the summary" no longer overlaps the first words; the summary eases in after it.
- Closing a summary, the card grows back to the page's full height, with no grey gap above the bar.
- Closing a summary stops it; it no longer finishes writing in the background, spending Claude tokens on Croatian pages.
- Closing Browse for Me mid-answer no longer flips the page to finished as it slides away, or starts another AI engine.
- A picture that won't load is removed instead of staying an empty tile, and the same picture no longer shows twice.
- Bold terms no longer show their asterisks while an answer is streaming in.

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
