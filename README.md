# roko

A fast, private iOS browser in the spirit of Arc Search, with Raycast's command-bar feel.
The Xcode project and code are still named `Browser`; only the name on the home screen is roko.
The app icon is drawn by `swift Scripts/make_app_icon.swift Browser/Resources/Assets.xcassets/AppIcon.appiconset`.
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
2. In the app, Settings → Passkeys → Allow passkeys.

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
(`AI/AnswerLanguage.swift`). Whether Apple's models write a language well comes from
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

## Notify Me

Like Safari's: in a page's menu, say what to look for (or nothing, for anything new) and how
often to check. `Watcher` reads the page with plain HTTP, off the main thread: one line per
paragraph, list item or heading, plus the page's JSON-LD offers ("Offer: Linen Shirt M, 39.95
EUR, in stock") and its `<option>` choices, marked when unavailable. It compares the lines with
the last reading. For anything new, new lines of real text (not a clock or a counter) go to
Apple's on-device model, which writes the notification. For something specific, the model
answers about one version of the page at a time ("does it show it? quote the line"), and roko
notifies only when the answer turns from no to yes; asked about added and removed lines at once,
the small model announced "back in stock" for a size that had just sold out.

iOS wakes roko for these checks (`BGAppRefreshTask`) when it chooses, so "hourly" means at most
hourly; roko also checks whatever is due when you open it. Pages that only show their text once
their scripts run are read in a hidden web view, which works only while roko is open. To force
every check in a Debug build, launch with `-checkWatches`.

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
permission prompt. To see the link itself first, turn on Settings → Show the link you copied
and set roko's Paste from Other Apps to Allow in iOS Settings; otherwise iOS asks for each
link. A link to the page already on screen isn't offered.

## Cookie pop-ups

roko answers cookie pop-ups instead of only hiding them, with DuckDuckGo's
[Autoconsent](https://github.com/duckduckgo/autoconsent) (MPL-2.0), the library DuckDuckGo's
own iOS browser uses: about 1,200 rules for consent platforms and single sites (Consent-O-Matic's
among them), plus a heuristic that finds a pop-up by its buttons. `Scripts/build_consent.sh`
bundles it with `Scripts/consent/bridge.js` into `consent-main.js` (pages, every rule) and
`consent-frame.js` (frames, the frame rules only). They run in their own content world;
`ConsentHandler` decides each answer.

- **Reject** by default. A known pop-up is kept hidden while it's answered.
- **Accept only where a site needs it**: rejecting didn't get past the pop-up (a cookie wall),
  or the page shows a platform's "accept cookies to see this video" placeholder. roko accepts
  through the platform's API, or reloads with the site's consent platform unblocked (the
  cookie list blocks many), and, if the site kept an earlier "rejected", resets that site's
  data once. The site is remembered, and Site Settings → Reject cookies shows and changes it.
- **Two reloads** of the same page within two minutes offer "Allow cookies", as Arc does.

Cookie banners the cosmetic list hides are faded (opacity) for ten seconds before being
removed, so Autoconsent can still find and answer them. Measured on an iPhone 17 Pro with the
`-benchmark -benchConsent` harness, the scripts made no measurable difference to page loads.

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
