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

Three features need managed entitlements that Apple grants on request to a paid
developer account. Until then the app runs without them and never touches them.

| Feature | Entitlement | Request |
| --- | --- | --- |
| Passkeys on websites | `com.apple.developer.web-browser`, `com.apple.developer.web-browser.public-key-credential` | Default-browser entitlement request (developer account) |
| Apple's cloud model for Summarize and Browse for Me | `com.apple.developer.private-cloud-compute` | developer.apple.com/contact/request/private-cloud-compute/ |

The app already meets the browser requirements (it declares http/https and opens to an
address field). Once granted:

1. Uncomment both `CODE_SIGN_ENTITLEMENTS` and `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
   in `project.yml`, then run `xcodegen`. Remove any key from `Browser/Browser.entitlements`
   that Apple hasn't granted yet, or signing fails.
2. In the app, Settings → Passkeys → Allow passkeys.

Never set `PRIVATE_CLOUD_COMPUTE` without the cloud entitlement: Apple's framework stops the
app rather than reporting an error.

## AI engines

| Feature | First choice | Then | Last resort |
| --- | --- | --- | --- |
| Summarize | Apple's cloud model (needs the entitlement) | On-device model | Claude (API key) |
| Browse for Me | Our search and page reading, then Apple's cloud model | Claude with its own web search | Our search and reading, then the on-device model |

Browse for Me searches DuckDuckGo's HTML results, reads the top five pages in parallel
(plain HTTP, no web views), and hands their text to the model with the question.

## Not done yet

- iCloud sync (the data model is already CloudKit-compatible).
- A count of blocked items: WebKit doesn't report blocks to the app.
- Default-browser status needs Apple's browser entitlement, which is requested separately.

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
