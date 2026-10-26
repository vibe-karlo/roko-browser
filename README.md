# roko

A fast, private iOS browser in the spirit of Arc Search, with Raycast's command-bar feel.
The Xcode project and code are still named `Browser`; only the name on the home screen is roko.
The app icon is drawn by `swift Scripts/make_app_icon.swift Browser/Resources/Assets.xcassets/AppIcon.appiconset`.
The alternates in Settings → App icon come from `swift Scripts/make_alternate_icons.swift
Browser/Resources/Assets.xcassets`: marks drawn in the script, and whole designed tiles from
`Scripts/icons/*.svg` (named for their icon set) rendered as they are.
SwiftUI shell around WebKit, no third-party dependencies.

## Run it

```bash
brew install xcodegen
xcodegen
open Browser.xcodeproj
```

Pick an iPhone simulator (iOS 26 or later) and run. On a real iPhone, set your team under
Signing & Capabilities first.

Summarize works out of the box on Apple Intelligence devices. Browse for Me (and summaries
on older iPhones) needs a Claude API key: paste it in Settings, where it's stored in the
Keychain.

## How it's built

| Area | Where | Notes |
| --- | --- | --- |
| Tabs | `Web/BrowserTab.swift`, `App/BrowserModel.swift` | At most 3 live web views; older tabs hibernate to a snapshot plus their back/forward state. Saved after every page load. |
| Ad, tracker, cookie blocking | `Blocking/`, `Resources/Blocklists/` | Request blocking uses WebKit content rule lists (native, compiled once). Element hiding is served per page by `CosmeticFilter`: a page gets only the selectors whose id or class it contains, instead of WebKit testing ~45k selectors on every page. |
| Cookie banners | `Resources/Scripts/cookie-consent.js` | Clicks "reject" on the common consent platforms, in an isolated script world; the cookie filter list hides the rest. |
| Command bar | `Command/` | One ranked list: address, search, Browse for Me, pins, tabs, history, suggestions, actions. Best match sits above the field. |
| Calculator | `Calculator/` | Raycast-style answers in the command bar: arithmetic and percentages, unit conversion (Foundation's units), currency (ECB rates via frankfurter.dev, cached 12 h), time in other cities. Go copies the answer. Non-maths text is rejected in about 9 µs. |
| Pop-ups | `Scripts/extra/popups.txt` | Fanboy's Annoyances (minus its cookie rules) plus our own additions such as Piano subscription modals. Allowed per site in page tools; hidden overlays that froze scrolling get scrolling back. |
| Summarize | `AI/Summarizer.swift`, `AI/PageReader.swift` | Mozilla Readability extracts the article; Apple's on-device model summarizes; Claude is the fallback. |
| Browse for Me | `AI/ClaudeClient.swift` | Claude Messages API with server-side web search, streamed. Swap `endpoint` for your own proxy before an App Store release. |
| Look | `UI/Theme.swift`, `UI/Glyph.swift` | One warm palette, one clay accent, a hand-drawn icon set whose boxes share a chamfered corner. |

## Updating the filter lists

```bash
python3 -I Scripts/build_blocklists.py
swift Scripts/verify_blocklists.swift
```

The first converts EasyList, EasyPrivacy and Fanboy's Cookie List to WebKit's format; the
second compiles them with the real WebKit engine to prove they load. Bump the build number
when you ship new lists so the app recompiles them.

## Speed

Measured with the built-in benchmark (7 news and reference sites, 3 cache-free loads each):

| Setup | Total time to first paint | Total load |
| --- | --- | --- |
| Hiding rules inside WebKit's lists (before) | 3172 ms | 8543 ms |
| On-demand hiding (now) | 1800 ms | 5418 ms |

Other choices that keep it quick: at most 3 live tabs, with off-screen tabs fully suspended;
video waits for a tap; no phone-number/date scanning of page text; the command bar resolves
the top result's address while you type; a restored tab shows its snapshot and only loads
once blocking is ready.

To measure, run a Debug build with launch arguments:

```bash
xcrun simctl launch --console-pty booted com.growthstudio.roko -benchmark
```

`-benchmark` prints one `BENCH` JSON line per site; `-perf` (works in Release too) prints
launch timings and each hiding request.

## Apple's permissions

These features need managed entitlements that Apple grants on request to a paid
developer account. Until then the app runs without them and never touches them.

| Feature | Entitlement | Request |
| --- | --- | --- |
| Passkeys on websites | `com.apple.developer.web-browser`, `com.apple.developer.web-browser.public-key-credential` | Default-browser entitlement request (developer account) |
| Saved passwords suggested for the site you're on (without it, iOS offers only the Passwords key and a full list) | `com.apple.developer.web-browser` | Default-browser entitlement request (developer account) |
| Apple's cloud model for Summarize and Browse for Me | `com.apple.developer.private-cloud-compute` | developer.apple.com/contact/request/private-cloud-compute/ |

The app already meets the browser requirements (it declares http/https and opens to an
address field). Once granted:

1. In `project.yml`, swap the active `CODE_SIGN_ENTITLEMENTS` and
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS` lines for the commented ones below them, then run
   `xcodegen`. `Browser/Browser.entitlements` carries iCloud's entitlements too. Remove any key
   Apple hasn't granted yet, or signing fails.
2. In the app, Settings → Privacy and sync → Allow passkeys.

Never set `PRIVATE_CLOUD_COMPUTE` without the cloud entitlement: Apple's framework stops the
app rather than reporting an error.

## AI engines

| Feature | First choice | Then | Last resort |
| --- | --- | --- | --- |
| Summarize | Apple's cloud model (needs the entitlement) | On-device model | Claude Haiku (API key) |
| Summarize, in a language Apple's models write badly | Claude Haiku (API key) | Apple's cloud model | On-device model |
| Browse for Me | Our search and page reading, then Apple's cloud model | Claude with its own web search | Our search and reading, then the on-device model |
| Browse for Me, in a language Apple's models write badly | Claude with its own web search | Apple's cloud model | On-device model |

Settings → Answer language picks what summaries, Browse for Me and Notify Me write in:
Automatic (the page's or the question's own language) or one of about thirty languages
(`AI/AnswerLanguage.swift`). One page holds both: Write in (the default), and Keep as they are, the languages left
alone: a page or question in the chosen language or a kept one is written about in its own
language, any other in the chosen one (Croatian, keeping English: Croatian and English pages
stay as they are, a German one comes in Croatian). Cached summaries are keyed by both, so
changing either writes them afresh. Whether Apple's models write a language well comes from
`SystemLanguageModel.supportsLocale`, except Croatian, Serbian and Bosnian: tested, they write
those with mixed-up words and broken endings whatever the prompt says, so those go to Claude
first when there's a key. When Apple's models do handle one (no key, Claude off or failing),
they write in English and say why. Croatian, Serbian (Latin or Cyrillic) and Bosnian each
name their standard in the prompt, and Claude is told to restate source facts in the answer's
language rather than copy them, since Haiku pasted English and Serbian sentences into Croatian
answers. Claude summaries and answers use Haiku 5.5, retried on Sonnet 5.5 only if Haiku
declines (not when the connection drops).

Browse for Me judges each question from its words (`ResearchDepth`): a quick fact reads three
pages (Claude: Haiku, low effort, two searches); an ordinary question six (Haiku, three
searches); a comparison, a "best", a decision or a plan eight (Sonnet, medium effort, six
searches) and gets a longer answer. Claude always searches before answering, with the basic
search tool: the newer one filters results by running code and was two to three times slower
on a phone. Our own search uses DuckDuckGo's HTML results and reads the pages in parallel
(plain HTTP, no web views).

To time Browse for Me on a phone, launch a Debug build over the cable:
`xcrun devicectl device process launch --console --device <id> com.growthstudio.roko -- -perf -browse "question"`.

## Shopping

A list that sorts itself into aisles (`Shopping/`). `Aisle.of` reads an item's words, Croatian
or English, after folding case and accents and dropping amounts ("2x Mlijeko 1L" is "mlijeko"):
whole words, stems ("mlijek" for mlijeko, mlijeka, mlijekom) and phrases ("kokosovo mlijeko"),
each weighted. What a thing is outranks what it tastes of ("sok od naranče" is a drink, not
fruit: fruit and vegetables count only on their own); a few words settle it whatever else is
said ("smrznuto", "za pse", "gel za tuširanje"). A lookup takes about 0.1 ms. Words no rule
knows go to Apple's on-device model in the background, and an item moved to another aisle is
remembered (`ShoppingHabit.chosenAisle`). `Scripts/test_aisles.swift` checks it: 173 things
people type, 101 items from October's Kaufland receipts (99 right; the two left are till
abbreviations), and, given a shop's published price list, how its groups land (cleaning 80%
Household, cosmetics 70% Personal care, drinks 70% Drinks).

Each item added counts towards its `ShoppingHabit`: how often, and the days between (a second
add the same day isn't another shop). Suggestions are habits bought at least twice and not on
the list, those whose usual gap has come round first. While typing, the last piece (after a comma)
is finished from habits, then `everyday.txt` (346 everyday things, Croatian and English, kept by
hand), then `products.txt` (4,563 names from one Osijek hypermarket's published price list, built
by `Scripts/build_shopping_catalogue.py`, which leaves out till abbreviations and sizes).
`ShoppingCatalogue` reads both once, off the main thread, as Shopping opens (30 ms); a match
scans them in under 3 ms. Items bought more than a month ago are
dropped from the list; habits stay. The list speaks English or Croatian (`ListLanguage`, Settings → Shopping list language): aisle names and its own words, with Croatian number forms ("svaka 3 dana", "svakih 5 dana", "21 stvar"); reading what's typed doesn't depend on it. Debug builds take `-seedShopping` for a few months of
habits. Items and habits live in `device.store`: sharing a list with family will be CloudKit
sharing, which needs the paid Developer Program (see "iCloud sync").

## Notify Me

Like Safari's: in a page's menu, say what to look for (or nothing, for anything new) and how
often to check. `Watcher` reads the page with plain HTTP, off the main thread: one line per
paragraph, list item or heading, plus the page's JSON-LD offers ("Offer: Linen Shirt M, 39.95
EUR, in stock") and its `<option>` choices, marked when unavailable. It compares the lines with
the last reading. A page with too little of those (glas-slavonije.hr is all boxes and links) is read by its links' text instead; `-pageLines <url>` prints a page as Notify Me reads it in a Debug build. For anything new, new lines of real text (not a clock or a counter) go to
Apple's on-device model, which writes the notification. For something specific, the model
answers about one version of the page at a time ("does it show it? quote the line"), and roko
notifies only when the answer turns from no to yes; asked about added and removed lines at once,
the small model announced "back in stock" for a size that had just sold out.

iOS wakes roko for these checks (`BGAppRefreshTask`) when it chooses, so "hourly" means at most
hourly; roko also checks whatever is due when you open it. Pages that only show their text once
their scripts run are read in a hidden web view, which works only while roko is open; their
row in Settings says so. Each run books the next wake-up, including one that finds a check
already running. Settings → Notify Me says when something stops it quietly: notifications off,
Background App Refresh off, or Low Power Mode. To force every check in a Debug build, launch
with `-checkWatches`; with `-perf`, each step is logged (`WATCH`).

## Not done yet

- iCloud sync is built but off: it needs the paid Apple Developer Program (see "iCloud sync").
- A count of blocked items: WebKit doesn't report blocks to the app.
- Default-browser status needs Apple's browser entitlement, which is requested separately.

## iCloud sync

Pins and history sync through CloudKit, in the private database of the iCloud account
(container `iCloud.com.growthstudio.roko`). `Store` keeps two SwiftData stores: `synced.store`
for `Pin` and `HistoryEntry`, and `device.store` for `SavedTab` and `Watch`. Open tabs are saved
after every page load with their back and forward history, which would only churn the sync, and
Notify Me would check and notify on every device. The first launch with sync copies the old
single `default.store` into the two and keeps it as `before-sync.store`. Settings and per-site
choices (search engine, blocking, cookies, zoom) sync through the iCloud key-value store
(`SettingsSync`); the app icon, the Claude key and caches stay on the device.

Records can't be unique in CloudKit, so two devices can add the same page before they hear
from each other: `Store.mergeDuplicates` folds those at launch and when roko comes back to the
front. Deletions go one by one rather than as a batch, so they reach iCloud too.

**Off until the team is in the paid Apple Developer Program**: a Personal team can't sign
iCloud or push notifications. Then uncomment `CODE_SIGN_ENTITLEMENTS` and
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` under "iCloud sync" in `project.yml`, run `xcodegen`, and
build with an Apple ID in Xcode (Settings, Accounts): automatic signing adds iCloud and push
to the app ID and creates the container. Without the flag the same two stores are used, on the
device only. Builds use the development CloudKit environment; before an App Store release,
deploy the schema to production in the CloudKit Console.

Continuing between devices: roko hands the page on screen off through Handoff (a Mac's Dock
opens it in the Mac's default browser, private tabs never). iOS hands web pages from a Mac
to Safari only, so the way back is Universal Clipboard: copy a link on the Mac, and roko
offers it above the bar once when you open roko, then in the address bar for five minutes. It
only checks that there is a link; the system Paste button hands the link over, which needs no
permission prompt (and finds the link in a pasted sentence). To see the link itself first, turn
on Settings → Show the link you copied and set roko's Paste from Other Apps to Allow in iOS
Settings; otherwise iOS asks for each link. Then roko reads the whole copy and offers it only
when it's one link on its own: iOS's own check says yes to a sentence that mentions index.hr
and to "CHANGELOG.md". A link to the page already on screen isn't offered, nor one offered or
opened from an earlier copy in the last three days.

## Cookie pop-ups

roko answers cookie pop-ups instead of only hiding them, with DuckDuckGo's
[Autoconsent](https://github.com/duckduckgo/autoconsent) (MPL-2.0), the library DuckDuckGo's
own iOS browser uses: about 1,200 rules for consent platforms and single sites (Consent-O-Matic's
among them), plus a heuristic that finds a pop-up by its buttons. `Scripts/build_consent.sh`
bundles it with `Scripts/consent/bridge.js` into `consent-main.js` (pages, every rule) and
`consent-frame.js` (frames, the frame rules only). They run in their own content world;
`ConsentHandler` decides each answer.

- **Reject** by default. A known pop-up is kept hidden while it's answered.
- **Through the platform's API** when no rule sees the pop-up: index.hr's anti-adblock scrambles ids and classes for everything but its own scripts, so Didomi is asked in the page itself whether its notice is up, and answered there. Page-script checks get a second each, so one that never answers can't stall detection. Debug builds take `-domProbe <script>` to look at the open tab from the page's world and the consent world.
- **Accept only where a site needs it**: rejecting didn't get past the pop-up (a cookie wall),
  or the page shows a platform's "accept cookies to see this video" placeholder. roko accepts
  through the platform's API, or reloads with the site's consent platform unblocked (the
  cookie list blocks many), and, if the site kept an earlier "rejected", resets that site's
  data once. The site is remembered, and Site Settings → Reject cookies shows and changes it.
- **Two reloads** of the same page within two minutes offer "Allow cookies", as Arc does.

Cookie banners the cosmetic list hides are faded (opacity) for ten seconds before being
removed, so Autoconsent can still find and answer them. Measured on an iPhone 17 Pro with the
`-benchmark -benchConsent` harness, the scripts made no measurable difference to page loads.


Bars a site writes itself, in words Autoconsent's heuristic doesn't recognise, get roko's own
fallback in `Scripts/consent/bridge.js`: when no platform is found after 1.5, 3.5 and 7 seconds,
it looks at the page's top-level boxes and anything named like a cookie notice for a pinned
(fixed or sticky) one that mentions cookies and has a button whose whole label is a no
("Reject", "Decline", "Only necessary", "Odbij", "Ablehnen"…). roko is asked as for any pop-up,
and the reject button, or the accept one where cookies are allowed on the site, is pressed.
Whole labels only, so a sentence containing "reject" is never clicked.
## To-do and Today

To-do (`Models/Todo.swift`, `UI/TodoView.swift`) is one list of SwiftData models in the synced
store. Each to-do keeps only the day it's for (or none, for Someday, or a week's last day for
This week), and its section is worked out from that and today's date, so nothing needs moving
as days pass. "to-do" or "todo" typed in full opens it, with today's to-dos listed under the row
to tick off; "todo" and a task (`TodoDraft`) adds one, a trailing day word picking the day, and
any other query offers Add to-do under Browse for Me. A trailing day and time ("on Monday at
15", "u petak u 15h", "next week", "24.11.") are read off the words (`TodoDraft.read`), in the
bar and in the To-do list's own field, whose chip shows what was understood. A to-do with a time (`time`, an absolute date) gets a notification 15
minutes before (`Today/TodoAlerts.swift`): they're laid out again after every save that touches a
to-do (`ModelContext.didSave`, filtered to Todo so page visits don't trigger it), at most 40.
Dragging sets `order` across the section it lands in, and moves it to that section's day. While
anything is due today, the to-do icon leads the bar's pins with a count.

Today (`Today/`, `UI/TodayView.swift`) opens the first time roko comes up after 4 a.m. each
day, and with "today". It reads:

- **Weather** from [Open-Meteo](https://open-meteo.com) (free, no key, CC BY 4.0, credited on
  the page), at a reduced-accuracy location (the town name from MapKit), or at a town picked by
  name with Open-Meteo's geocoding, which needs no location permission.
- **Calendar** with EventKit's full access, asked for from the page; events stay on the phone.
  Calendars can be left out (Today → Calendars); the ones left out are stored, so new ones show.
- **News** from the RSS or Atom feeds of the sites chosen in Settings → Today and to-dos (thirteen
  suggested, any other found by its address). A page of a site (a club's news) is followed
  on its own: its section's feed if there is one, else its headlines read from the page
  (`PageHeadlines`: links into the section, the element named for the headline, dates from
  the address). Topics are matched in the major Croatian feeds and your own: a stem of the
  topic's longest word, then, for multi-word topics, the on-device model keeps only those
  really about it. A club ("NK Osijek": NK, HNK, KK, RK…) is looked for on sport pages only, or by its full name, so the city's news stays out. Google News has no Croatian edition, so it isn't used. Apple's on-device model picks the front page
  from up to sixty headlines, each site's newest in turn (newest overall, a site that posts all
  day crowded the others out), then is asked about just its picks which only announce something
  (a club night, a film programme, a sale), and those go. At most two stories per site, filled
  from the rest of the model's picks, never the newest; headlines sharing most of their words,
  or two in a short headline, count as one story. Without the model, each site's newest. To try
  the pick on a fixed day of headlines in a Debug build, launch with `-topProbe`.

What it last showed is kept in `today.json`, so it opens at once. The weather and calendar
are fetched on every opening; everything refreshes with a tap on "Updated", when opened
more than half an hour later (there's no pull to refresh: a pull down closes it, as To-do and
Browse for Me do), and in a background refresh iOS runs from about 5:30. A refresh that brings
nothing (offline) leaves what was there. Measured in the simulator: weather and four sites,
sixty stories and the pick, 4.6 to 5.6 s; nothing runs while Today isn't open or being
prepared.

Reminders (`Today/DailyReminders.swift`) are local and passive (no sound): 8:30 if Today hasn't
been opened that day, 16:00 if today's to-dos are open. They're worked out again whenever roko
goes to the background or Today opens, so one never reports something already done.

## Sharing answers

Share in Browse for Me turns the page into a short link anyone can open, as Arc does. The
server is `Server/share`, a Cloudflare Worker with a D1 database, both on Cloudflare's free
plan. Nothing is uploaded until Share is tapped. Sharing again after a follow-up updates the
same page. Settings → Shared pages lists what this iPhone shared; swipe one to unshare it.

- **The page** (`src/page.js`) lays the answer out as the app does, in the app's palette,
  light or dark, with the topic icons copied from the app (`npm run icons`). It has no
  scripts but one that removes a picture that fails to load, allowed by its hash in a strict
  Content Security Policy. Link previews (iMessage, WhatsApp, Slack) get the title, the gist
  and the first picture. Site icons are fetched through the Worker, so readers' browsers only
  talk to it. Search engines are told not to list pages until `INDEXABLE` is `"true"`.
- **What's kept**: the page itself, a hash of its edit token (the app keeps the token), and a
  salted hash of the sharer's IP address, used only to cap shares at ten a minute and a hundred
  a day per address.
- **Tests**: `npm test` (parsing and escaping), and with `npm run dev` running,
  `node test/api.e2e.mjs` (create, view, update, unshare, bad input, limits).
- **Testing the app against it**: `npm run dev`, then launch a debug build with
  `-shareServer http://127.0.0.1:8787`.

Deploying, once there's a domain:

1. Add the domain to a Cloudflare account, then on this Mac: `cd Server/share && npm install
   && npx wrangler login`.
2. `npx wrangler d1 create roko-shares`, and put the id it prints in `wrangler.jsonc`.
3. In `wrangler.jsonc`: set `PUBLIC_URL` (e.g. `https://roko.app`), `REPORT_EMAIL` if pages
   should have a Report link, and uncomment `routes` with the domain.
4. `npx wrangler secret put ADDRESS_SALT` with any long random string, then `npm run deploy`.
5. In `project.yml`, set `SHARE_SERVER` to the same address, then `xcodegen generate` and build.

To take a page down by hand: `npx wrangler d1 execute roko-shares --remote --command
"DELETE FROM shares WHERE id='<id>'"`.

## Credits

Icons: [Phosphor Icons](https://phosphoricons.com) (regular and bold), MIT License,
Copyright (c) 2023 Phosphor Icons. They live in `Browser/Resources/Assets.xcassets/phosphor`.

```
Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify,
merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be included in all copies
or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Speed and battery, measured

On the iPhone 17 Pro, Release build (24 October 2026): first screen 160 ms after launch warm, 460 ms
cold; the content blocker ready 0.4 to 1.2 s. In the simulator: every screen (a page, the address
bar, Today, To-do, an answer) at 0% CPU when nothing is happening, about 80 MB; ranking the
address bar 1 to 2.5 ms a keystroke, 3.5 ms to open. Nothing polls: waits are one-off pauses or
debounces, the light's breathing and the reading shimmer run only while something is being worked
on, and the network and location are touched only when what they'd bring is stale (weather ten
minutes in Today, half an hour pinned; a location fix fifteen minutes). In the background: one
morning refresh for Today, Notify Me's checks, and local notifications.

With -perf: `PERF` lines for launch, `PERF rank` for each keystroke, `HITCH` for frames over 40 ms
while a summary opens, `SUMMARY` for its first words.

## Speaking to the bar

Holding + (`BottomBar.holdToTalk`, a third of a second) starts `VoiceInput`: `SFSpeechRecognizer`s
for hr-HR and en-US fed the same microphone buffers, on the device where the language allows it.
The live words go into the launcher's field; on release each recognizer's final transcription is
scored by its mean segment confidence (Croatian letters tip a close call to Croatian) and the best
kept. `VoiceCommand.interpret` turns spoken addresses ("dot", "točka", "slash", "w w w") and
"open"/"otvori" plus a name into a known host (history first, then `PopularSites`, hyphens ignored)
and opens it; everything else goes to the bar's own ranking, where `TodoIntent` puts a to-do first.

## Settings

One screen, grouped by what you do, with long lists on pages of their own. It opens on what roko
has saved you (`App/SavedStats.swift`): counts in UserDefaults, bumped where each thing happens
(the consent bridge's `rokoSaved` message, a summary or Browse for Me answer finishing, the bar
closing on an answer, once each time it's open), and turned into time by stated estimates.

- **Appearance**, and the app icon (its own page).
- **Address bar**: search engine, suggestions, the copied link, ticks as rows go by.
- **Voice**: hold + to speak, and which languages it listens for (Croatian and English
  together, or one of them).
- **Pages**: pull further to summarize (off, a pull only reloads), closing unused tabs, and
  what's blocked (its own page).
- **Today and to-dos**: opening Today each morning, the two daily nudges, alerts before a
  to-do's time, news, calendars, weather place.
- **Summaries and answers**: answer language, Claude and its key, Notify Me (its own page).
- **Privacy and sync**: iCloud status, passkeys, shared pages (their own page), clear history.

Feature switches live in `Preferences` and are read where each feature runs, so turning one off
takes effect at once. Voice languages and pull to summarize sync with the other settings; the
haptics and alerts belong to the device.

## What pages can ask

`PageDialogs` answers what a page asks outside itself. alert(), confirm() and prompt() are
system dialogs titled with the site's host, shown only for the page on screen. A link tapped to
another app (tel:, mailto:, the App Store) opens it; one opened by a redirect or a script asks
first. Files a page hands over (`Content-Disposition: attachment`, a `download` link, or a type
WebKit can't show) download to a temporary folder and open in the share sheet, or in Wallet for a
`.pkpass`. The delegate methods there are `@objc`: WebKit finds them by selector, and they sit
outside the extension that declares the conformance.

## Parking

Paying for street parking by text (m-parking), in the cities in `Parking/ParkingCity.swift`: for now
Osijek, with GPP Osijek's zones, numbers, prices, limits and charging hours (Croatian public holidays
are free, Easter-based ones worked out). Typing "parking" asks for one precise location fix
(`ParkingLocation`; with precise location off for roko, iOS is asked for it just this once, under the
"Parking" purpose in Info.plist) and matches it to the city's paid parking areas, bundled as
`Resources/Parking/<city>.json` from OpenStreetMap (© OpenStreetMap contributors, ODbL) by
`python3 Scripts/build_parking.py`. Within 60 m of an area counts; another zone within 25 m of the
nearest is offered too, since a wrong zone means a fine. Found nothing, roko says to check the signs
rather than that parking is free: cities extend zones faster than the map follows.

roko never sends the text: Messages opens with the number and the registration (Settings → Parking)
written in, and only a sent message starts the timer. The session is kept in UserDefaults, and runs
as a Live Activity (`Shared/ParkingActivity.swift`, drawn by the `RokoWidgets` extension in
`Widgets/`) whose countdown iOS draws on its own, with nothing updating it. One text buys an hour;
the end never goes past the end of charging, and "Add an hour" stops at a zone's daily limit
(Osijek's zone 0: three hours). Launch with `-parkingTest` to have a simulator, which can't send
texts, act as if each one was sent.

Adding a city: its zones and numbers in `ParkingCity`, its bounding box and zone tags in
`Scripts/build_parking.py` (or another source of zone outlines, such as Zagreb's ArcGIS layers), then
rebuild the data.

## Widgets

The `RokoWidgets` extension (`Widgets/`) has three Home Screen widgets and the parking Live
Activity. They can't read roko's store, so the app writes a small copy into the App Group
`group.com.growthstudio.roko` (`Shared/WidgetSnapshot.swift`): the to-dos due by tomorrow, the
current weather and the bar's pinned answers. `App/WidgetBridge.swift` writes it after every save
that touches a to-do, every new weather and every time the bar lists your pins, and only when it
changed, which is also the only time widgets are asked to reload. A widget's timeline holds now
and midnight, when tomorrow's to-dos become today's.

Ticking a to-do in a widget runs `CompleteTodoIntent` in the extension: it adds the to-do's id to
a list in the group's shared defaults and the widget redraws without it. roko takes the list and
marks those done at launch and each time it becomes active.

The App Group is in `Shared/AppGroup.entitlements` (both targets), and in `Sync.entitlements` and
`Browser.entitlements` for when either is switched on. Automatic signing registers it on the
team; the first build after adding it needs Xcode's Signing & Capabilities to have the team set.

## Reminders

`Today/RemindersSync.swift` keeps to-dos and one Reminders list (EventKit, full access, asked
when the switch is turned on) the same, both ways. Each to-do keeps its reminder's
`calendarItemIdentifier` and a fingerprint of both sides at the last sync (title, day, time,
done); on each round the side that no longer matches it changed, and the other is brought in
line, Reminders winning when both changed. Unlinked to-dos go into the list (a reminder that reads
the same, from another device, is taken rather than duplicated), unlinked reminders become
to-dos, and the set of linked ids tells a deletion on one side from something new on the other.
Rounds run at launch, on becoming active, after a save that touched a to-do and on
`EKEventStoreChanged`, a second apart at most, and skip the changes they made themselves. A round
is a few tens of milliseconds. Completed reminders older than two weeks aren't looked at.
