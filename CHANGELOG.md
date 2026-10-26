# Changelog

All notable changes to roko. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Hold + to speak. The address bar opens out of it, listening, with the words coming into the field as they're heard and the rows following; let go and it's done. English and Croatian are heard at once, each by its own recognizer on the same sound, and the clearer hearing wins, so there's no language to pick. Said as an address ("index točka hr", "theverge dot com slash tech", "w w w dot bbc dot com") or as "open"/"otvori" and a site ("otvori index", "open youtube"), a site roko knows opens at once, matched to your history and well-known sites ("glas slavonije točka hr" is glas-slavonije.hr). Anything else goes into the bar as typed, its best row ready: a to-do ("sutra nazvati mamu u 5", "remind me to pay rent on friday"), a question for Browse for Me, a search. A day said first is read too ("sutra nazvati mamu"). The microphone is on only while + is held.
- The address bar knows a to-do when it sees one: "call Petra tomorrow", "kupiti mlijeko", "remind me to pay rent friday", "dentist at 15" put the to-do first (titled as it will be added, "Pay rent, for Friday"), so Return adds it, as Browse for Me goes first for a question. It reads doing words in English and Croatian, "remind me to" and "ne zaboravi", and words followed by a day or time; questions and look-ups ("how to pay rent", "weather tomorrow") stay searches.
- Scrolling the address bar's list ticks for each row that passes under the field, like a picker wheel, while it's dragged or still gliding.
- Typing an address, the site comes first: "index" offers index.hr itself, its front page, ahead of the articles you read on it, whether in history or open in tabs; the articles follow below. A page open in several tabs is one row.
- The launcher's field goes to the top of the screen, as in Arc Search: it grows out of the bar's capsule and rises there in a fifth of a second, then the rows come in under it, down to the keyboard. Its place no longer depends on the keyboard, so a taller one (SwiftKey) or one that reports its size late can't make it jump.
- The launcher grows out of the bar for real: its field starts exactly on the capsule you tapped and widens and rises into place, with the keyboard coming up under it, then sinks back into the capsule on close. (The capsule used to fade out while a field appeared at the top: the frames it measured included its own movement, so it never moved.)
- To-do's field: the chip says when in short ("Wed 15:00") and is a menu (Today, Tomorrow, This Week, Someday, Date and Time…) for when the words don't say. "at 3" means 15:00 (1 to 6 are the afternoon), and a day typed first ("Wednesday at 3") is read too.

### Fixed
- Holding + to speak: the launcher no longer closes the moment you let go. Let go before saying anything and it keeps listening, stopping on its own after a pause in what you say (or eight seconds of nothing); a tap on the mic mark stops it too. Nothing heard, it stays open with the keyboard. And it taps when it starts listening and when it stops: recording had been silencing roko's haptics.
- Holding + didn't start listening: the bar's swipe gesture (to switch tabs) took every touch first, so the hold never reached +. And allowing speech recognition the first time crashed roko: iOS answered on a queue of its own into code that may only run on the main thread. Both fixed; the microphone's and the recognizers' callbacks are made off the main thread too.
- The address bar could close the moment it opened: the list passed its pull-to-close point on its own while laying itself out. Only a pull with a finger closes it now. And opened by roko itself (at launch with nothing open) it came up half-drawn and invisible, so the next tap on + closed it instead: its open state now lives in the app, not the view, which can be rebuilt while the app starts.
- Pull to refresh comes sooner (80 points past the top, was 100) and pull to summarize a little later (150, was 140), so the two are further apart.
- A link copied long ago is no longer offered. iOS doesn't say when something was copied, only that the clipboard changed: a copy from a Mac or iPad (Universal Clipboard, which marks what it brings and keeps it only a couple of minutes) is always fresh and still offered, but a link copied on the iPhone while roko was closed for more than five minutes could be a day old, so it isn't offered at all.
- Less network and location for the weather: pinned towns' weather is fetched again only when it's half an hour old (it was on every opening of the address bar, two requests a town); Today's weather when it's ten minutes old; a location fix from the last quarter of an hour is reused instead of waking GPS, and the town isn't looked up again within a kilometre of the last one.
- The address bar opens in 3.5 ms (was 7 to 24 ms, enough to drop a frame as the field starts to rise): a pinned answer is worked out by itself instead of by running the whole ranking for each one.
- A link copied on a Mac while roko is open is offered again: only copies made in roko itself are left out now.
- The bar is one capsule with one edge: its buttons and launcher capsule are plain fills inside it, their curves parallel to its own, instead of each drawing an outline at a different roundness. In To-do the field fills the bar.
- The launcher opens out of the bar: the bar's capsule is the launcher's field, so it widens and rises with the keyboard, and closing it sinks back into the bar, instead of one fading out while another fades in at the top.
- To-do types in place: "New to-do" widens into a field right in the bar, the list stays in view above, the chip says when ("Fri, 30 Oct"), and Return adds it into the list with the keyboard still up for the next. ✕ finishes.
- One bar across the app, shaped for the screen it's on: the browser's tabs, launcher and page menu; in To-do, close and "New to-do"; in Today, close, Search and Refresh; in Browse for Me, close, "Ask a follow-up" and Share; in a summary, close and "Ask about this page". The middle always opens the same launcher, set up for that screen: in an answer it asks a follow-up (or offers the suggested ones); in a summary it asks Browse for Me about the page, with the summary as context. To-do's own field at the bottom is gone.
- What's next on your calendar in the address bar: type "calendar", "next" or "kalendar" for the next event ("In 25 min, at 14:30 · Office", "Tomorrow at 9:00"); Return opens Calendar there. Pin it like the weather to keep it under the empty field.
- Pin answers like pages: long-press the weather ("vrijeme", "vrijeme u Zagrebu"), "days until 24.12.", "100 eur in usd" or any sum, and choose Pin. It sits with your pins under the empty address field, worked out again each time you open it; long-press to unpin.
- Feels like: Today's weather and the bar's weather rows say what it feels like (with wind and humidity) when that's different from the temperature.
- Town weather in Croatian forms and short: "vrijeme u Zagrebu", "u Rijeci", "u Zadru", and the plate codes "vrijeme zg", "os", "st", "ri"…; "vrijme" works too.
- Summaries are kept for a day: summarizing the same page again opens on its summary at once, with nothing spent.
- Long pages summarize fast on the iPhone: the summary starts from the page's opening, one pass (first words in about 2.5 s in the simulator), and while you read it, later parts of the page add a section or two below. It used to read every part before writing a word.
- A town's weather from the address bar: "weather in London", "london weather", "vrijeme u Zagrebu" answers first with its weather now (found by name through Open-Meteo); Return searches it.
- Today: tap the weather to open the Weather app (long-press it to choose the town), tap an event to open Calendar at its time.
- Pins are the first rows under the address field, as in Arc, marked with a pin and part of the scroll-to-pick (long-press one to unpin), after To-do with how many are left today.
- Type "weather" or "vrijeme" (or "forecast", "prognoza") in the address bar: the weather now, where Today's is for, as the first row; Return opens Today. Half an hour old, it's fetched again as you type.
- Summaries and Browse for Me answers are signed with roko's Eclipse mark and name in the footer, so a screenshot says where it came from. The footer is slimmer and sits lower, into the home indicator's strip.
- Swipe down on the open address bar (on its list or the page behind) to close it.
- The address bar, after Arc Search: the field sits on top and the rows below it, nearer the thumb, over the page frosted and dimmed behind them. The list snaps row by row like a picker; the row under the field is the one Return opens, and the field shows it (its icon, title and address) with a light tick as it changes, so a flick chooses. Typing brings your text back; the clear button returns to the top. With nothing typed: your pins, a link you copied, and your last pages to pick from.
- Done, at the bottom of To-do: folded under its count, it opens on what you ticked off in the last two weeks, the latest first, each a tap from being undone.
- Pull to summarize is one motion with the summary. From the first point of the pull the page is a picture of itself over the summary's dark (no grey strip, no site header left behind at the top); past the reload point it starts becoming the summary's card, and letting go carries on from that exact frame: the card tips back as it flies into place and comes upright as it lands, roko's light already rising behind it, and the summary sharpens out of a blur. Ease off and it settles back into the page. Shorter, too: about 300 points of pull instead of 370.
- To-do days and times in words work in the To-do list too, not only the bar: "Call dentist on Monday at 13" is added for Monday at 13:00, and the chip beside the field shows what it understood as you type.
- To-do days from the bar, in English or Croatian: weekdays ("on Monday", "u petak", "next Friday" for next week's), next week, the day after tomorrow ("prekosutra"), "in 3 days" ("za 3 dana") and dates ("24.11."), in either order with a time ("call Petra on Monday at 13:00").
- Today and To-do in the tab switcher's bottom row, either side of the new-tab button; To-do carries how many are left today.
- To-dos can have a time: long-press, Date and Time…, switch Time on. A notification (with sound, unlike the quiet daily reminders) comes 15 minutes before; it's withdrawn if the to-do is ticked off, moved or deleted. From the bar: "todo call Petra tomorrow at 15", "… u 15h", "… at 3pm" or "… 9:30". The time shows under the to-do, in Today and in the bar.
- Drag a to-do to reorder it, or into another section to move it there (into Tomorrow, This week, Someday…). The order holds in Today and the bar too.
- Today → tap the weather (or Settings → Today → Weather) to pick a town instead of where you are, found by name through Open-Meteo; a town needs no location permission.
- Today follows pages and topics, not just whole sites. Add a page by its address (glas-slavonije.hr/sport/nk-osijek) and it gets a section of its own with only its stories: from its own feed if it has one, else read from the page itself. Add a topic ("NK Osijek") and Today finds stories about it in the major Croatian news feeds and yours; for a topic of more than one word, Apple's on-device model drops the ones about something else that shares a word.
- The address bar as a launcher for to-dos. "todo call Petra tomorrow" (or "+call Petra") adds one, for today unless it ends in tomorrow, this week, someday or their Croatian words, and Return adds it. Anything else you type can be kept too: Add to-do sits under Browse for Me. Typing "todo" brings today's to-dos up under the To-do row, to tick off there; otherwise the bar shows only the to-do icon with how many are left, beside your pins.
- The orange light is smooth: its grain is one fine dot per screen pixel, a little either side of neutral, instead of full-strength noise drawn three times too big.
- Starting a summary no longer stalls the card on its way into place: the page's language is told off the main thread (it took over 100 ms there), and the page's picture is decoded during the pull.
- Today's weather fits the screen: the day's range and rain sit under the condition instead of running off the edge, and the next twelve hours show every other hour, spread across the width rather than scrolling off it.
- Today → Calendars (and Settings → Today → Calendars): pick which calendars Today shows, grouped by account. A calendar added later shows up until you untick it.
- Reminders, silent and at most two a day: at 8:30 if you haven't looked at Today, and at 16:00 if today's to-dos are still open (withdrawn once they're done). Tapping one opens Today or To-do. Settings → Today → Reminders turns them off.
- Today: the first thing roko shows on a new day, and there whenever you search "today". The weather where you are (Open-Meteo, from a rough location) with the next hours, what's left on your calendar (read on the iPhone), today's to-dos to tick off, and the top stories from news sites you choose: their feeds are read and Apple's on-device model picks the most important, at most two per site and never one story twice. It's kept on the iPhone and opens at once; the weather and calendar are fetched again every time it opens, and the news in the morning before you look (in the background), when opened more than half an hour later, or with a tap on "Updated" under the date. Pull it down to close it. Settings → Today turns the morning opening off and picks the sites.
- To-do: one list, opened by searching "to-do" (or "todo"), like Settings. It sorts itself into Overdue (with Move to Today), Today, Tomorrow, This week, Later and Someday. Tap the circle to tick one off, tap its words to change them, long-press to move it (Today, Tomorrow, This Week, Choose Date…, Someday) or delete it. New ones go in at the bottom, for Today unless you pick another time, and the keyboard stays up for the next. While anything is due today, the to-do icon sits on the start screen's pins with how many are left. Pull the list down to close it. To-dos join iCloud sync once it's on.
- iCloud sync, ready but off until the paid Apple Developer Program: pins, history, settings and what you chose for each site, on every device signed in to your iCloud. Open tabs and Notify Me stay on each device. Data already moves into the new layout on first launch.
- Handoff: the page on screen can be continued on your Mac, in its default browser. Never a private tab.
- Copy a link on your Mac and roko offers it ("Link you copied"), through Universal Clipboard: above the bar once when you open roko (gone once you scroll), then in the address bar until you close the bar without it (at most five minutes). Only a link copied while roko was away, in another app or on a Mac: one copied in roko is never offered back. It opens with the system Paste button, so iOS never asks for permission to paste.
- Settings → Show the link you copied: the offer and the address bar show the link itself, with its site's icon, before you open it. Set Paste from Other Apps to Allow in iOS Settings and iOS doesn't ask; links copied in roko always show.
- Settings → Appearance: Automatic, Light or Dark, for the whole app and the pages in it.
- Settings → Answer language: Automatic, or one of about thirty languages (Hrvatski, Srpski in Latin or Cyrillic, Bosanski, Slovenščina, Deutsch...) for summaries, Browse for Me and Notify Me. A language Apple's models write badly goes to Claude, and the setting says that's slower and paid.
- Text in Summarize and Browse for Me can be selected: long-press a word, drag the handles, then Copy, Look Up or Translate.
- roko's orange light in more places: it floods the whole screen as a Browse for Me answer or a summary arrives, then dissolves so the answer is read on dark; and it rises under "Answered by roko" at the end of a shared page.
- Share in Browse for Me, as in Arc: the page becomes a short link anyone can open, laid out as in the app (opening on the answer, without the question above it), light or dark, signed "Answered by roko" with the Eclipse mark. Sharing again after a follow-up updates the same link. Settings → Shared pages lists them; swipe to unshare. The server is in `Server/share` (Cloudflare Worker and D1), ready to deploy once there's a domain; until then Share is hidden.
- Full-screen Summarize: the page shrinks into a card, then the summary writes itself.
- Structured answers for Summarize and Browse for Me: a gist, then sections with topic icons.
- Browse for Me shows each site as it's read, with source cards, pictures and real site icons.
- Settings → App icon: thirteen alternates from the logo designs, including three Eclipse marks (cream, on orange, orange).
- Translate any page into English or Croatian, in place.
- Address suggestions show the real icon of 150 popular sites, bundled, with no network request.
- Haptics when a toast confirms an action, a tab is thrown away, or the bar swipes to the next tab.
- Settings → Use Claude: turn Claude off without deleting the API key; Apple's models then do everything.
- Browse for Me suggests two or three follow-up questions under the answer when they'd help. Asking one adds a new section to the same page, answered with the earlier answers as context.
- Tap a question in Browse for Me to reword it; that section and the ones after it are asked again.
- An AI / Google switch flips the Browse for Me page to the search results and back, from the start, losing neither. Closing the page stops any answer still being written.
- roko's orange light: while Browse for Me or Summarize works, a warm light rises from the bottom edge as pages are read, in one continuous motion, and sinks back into the edge when the answer starts.
- Browse for Me's answer arrives in order: the question shrinks to its heading, then pictures, sources and text ease in one after another.
- Browse for Me matches the question: a quick fact gets a short answer from three sources; a comparison, a "best" or a plan reads more sites and writes more.
- Answers written by Claude show pictures too, from the pages its searches found, fetched alongside while it works.
- A weather topic, with a sun, for answer sections about weather and seasons.
- Cookie pop-ups are answered, not just hidden: DuckDuckGo's Autoconsent (with Consent-O-Matic's rules) rejects them on about 1,200 consent platforms and sites, and finds the rest by their buttons.
- Cookies are accepted only where a site needs them: a cookie wall, or a video or embed held back until you accept. roko remembers the site and says so ("Accepted cookies: … needs them").
- Site Settings → Reject cookies: see and change what roko does with a site's cookie pop-ups.
- Reload a page twice and roko offers "Allow cookies" there, as Arc does.
- Notify Me, as in Safari: in a page's menu, say what to look for ("size M in stock", or nothing for anything new) and check hourly, daily or weekly. roko reads the page in the background, Apple's on-device model decides whether it's what you asked for, and a notification opens the page. Settings lists the watched pages.

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
- The bar floats over the page, as in Safari: pages run to the bottom edge with the bar showing or folded away.
- A pin always opens the page that was pinned, not whatever page of that site is open; two pages of one site can both be pinned.
- Summarize with a long pull from the top of a page instead of a pinch: past the reload point the ring closes and opens into "Summarize", with a firmer tap, and letting go there summarizes. Easing back off reloads instead. A pinch always zooms again.
- Apple's models write in English when they summarize a Croatian page or answer a Croatian question, and say why; Claude still writes Croatian.
- Browse for Me's light rises higher while it reads, to most of the screen, and is stronger.
- The Browse for Me switch says AI / Google instead of Answer / Google.
- The copied-link offer reads like the cookie one: what it is, then "Paste" or "Open" in orange, instead of a filled orange capsule. In the address bar it's a row like the others.
- Pins are just their sites' icons, above the field and on the start screen, on the same line as the icons in the list; a long press names the page.
- The address field's icons line up with the rows above it.

### Performance
- The light's grain is made from random bytes in well under a millisecond, instead of 90 ms through Core Image: a hitch the first time a light showed. The pull's light is drawn off the main thread after the first page; the first pull took 92 ms to draw it, now 0.2 ms.
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
- News about crimes or attacks is no longer refused by Apple's on-device safety filter as often.
- Summarize: "Writing the summary" no longer overlaps the first words; the summary eases in after it.
- Closing a summary, the card grows back to the page's full height, with no grey gap above the bar.
- Closing a summary stops it; it no longer finishes writing in the background, spending Claude tokens on Croatian pages.
- Closing Browse for Me mid-answer no longer flips the page to finished as it slides away, or starts another AI engine.
- A picture that won't load is removed instead of staying an empty tile, and the same picture no longer shows twice.
- Bold terms no longer show their asterisks while an answer is streaming in.
- Pages no longer stop short of the bottom edge, leaving a blank strip above the home indicator.
- Typing into a page, the bar stays behind the keyboard instead of covering the form, and the page reaches down to the keyboard instead of stopping short of it.
- Typing an address for a private tab no longer offers an open normal tab, which Return would switch to.
- Typing "settings" in full puts Settings first, so Return opens it instead of searching for the word.
- A copied link to the page already on screen isn't offered; nor is a link copied in roko, above the bar.
- A link copied long ago is no longer offered as new after roko restarts.
- The copied-link and cookie offers no longer stay on top of the page menu.
- Pages pushed down by a "Get our app" banner (smartbanner.js) no longer keep an empty band at the top once the banner is hidden.
- A Browse for Me follow-up on Apple's models searches with the page's question too: "how long does the festival last?" after Oktoberfest found Diwali.
- A page never waits more than three seconds for the block lists before loading.
- An English page that opens on foreign names (a Wikipedia town article) is summarized as English: when the text alone isn't clear, the page's own language tag decides. It was read as Catalan and summarized "in English" with a note.
- Claude pasted English and Serbian sentences from its sources into Croatian answers; it's now told to write every sentence in the answer's language and restate what sources say.
- A dropped connection while Haiku answers no longer starts the whole answer again on Sonnet, slower and dearer; only a refusal does.

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
