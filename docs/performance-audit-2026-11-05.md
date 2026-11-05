# Performance audit, 5 November 2026

Build audited: main at db1a3eb (0.1.1, build 11 plus the Duo bar commit), Release, on the iPhone 17 Pro over the cable. Code read in full for the launch path, page-load path, UI, and background work. Numbers below are measured unless marked as estimates.

## What the phone says

Launch, `-perf`, five runs, app ended between runs. Run 1 was the first launch after install; runs 2 to 5 are typical.

| Mark | Run 1 | Runs 2 to 5 (median) |
| --- | --- | --- |
| App init done | 113 ms | 74 ms |
| First frame | 194 ms | 158 ms |
| Web view built, 201 tabs restored | 227 ms | 183 ms |
| Rule lists ready | 310 ms | 237 ms |
| Blocker ready, hiding index ready | 335 / 344 ms | 242 / 296 ms |
| Restored page committed | 462 ms | 396 ms |

Launch is in good shape and matches the README's claims. The restored page waits for the blocker, then commits about 150 ms later. Nothing on the launch path needs urgent work.

Pages, opened by link into a running app (times from the request):

| Page | Commit | First paint | Finish | Hide round trips | Consent messages |
| --- | --- | --- | --- | --- | --- |
| theverge.com | 309 ms | 578 ms | 1.8 s | 12 | 88 |
| dailymail.co.uk (redirects to .com) | 308 ms, 605 ms | 666 ms | 3.1 s | 18 | 100 |
| forbes.com (blocking allowed on this phone) | 695 ms | 975 ms | 2.5 s | 0 | 0 |
| en.wikipedia.org | 246 ms | 288 ms | 0.8 s | 7 | 35 |

No frame over 40 ms was logged during any of these loads. Forbes shows what a page costs with roko's filtering off: it is on this phone's allowed-hosts list.

Memory with The Verge open: roko's own process 62 MB, the page's WebContent process 296 MB (that is the site, not roko).

The store on the phone: 205 saved tabs weighing 565 KB in total, 739 history entries, 26 to-dos. The device store file is 5.1 MB plus a 2.4 MB write-ahead log, and 122,041 of its rows are SwiftData change-history records for saved tabs. Every save deletes all 205 tabs and inserts them again, so each save writes about 410 history rows, and 457 such transactions ran today alone.

## Where the time goes, by feature

Ranked by how much each costs the person holding the phone, with a view on whether the cost is necessary.

### 1. Cookie pop-up answering (Autoconsent). The largest per-page cost, all of it after first paint. (Done the same day: frame gate, heuristics off, retries down, reports only with `-perf`. The Verge went from 88 messages to 35, none from frames.)

What was measured: 80 to 100 messages per ad-heavy page, among them 24 to 30 `eval` round trips (page to app to page, each with a one-second race timeout), 5 to 6 frames each receiving the 192 KB frame script, and about 50 `report` messages that nothing reads in Release.

What the code does on top: `detectRetries: 20` means up to 21 detection passes at 500 ms intervals, in every frame. `enableHeuristicDetection: true` reads `documentElement.innerText` on each pass, forcing layout and copying the page's text, and `bridge.js` never reads the result. The 496 KB main script is bridged from a Swift `String` to WebKit on every page.

Why the benchmark did not see it: the harness stops at `didFinish`, and this work runs in the 10 to 20 seconds after.

Necessary? Answering pop-ups is a headline feature and should stay. Most of its cost is not. Suggested, in order of payoff:
- In the bootstrap, test `location.href` against the 29 frame rules that carry URL patterns before posting `rokoLoad`; only two frame rules are generic. That removes nearly all frame evals.
- Set `enableHeuristicDetection: false` and `detectRetries` to about 5.
- Stop sending `report` messages unless `-perf` is on.
- Keep the two script sources as `NSString` so they are bridged once.
Estimated saving: a few hundred milliseconds of WebContent CPU per heavy page, plus less main-thread traffic in the app while the page settles.

### 2. Saving open tabs. Grows with tab count; this phone has 205. (Done the same day: incremental save from a context signed `tabs`, its history pruned after a day. Measured: one change per save instead of 410. The 122,000 old rows stay; the history can't be pruned per store, and the synced store's rows belong to CloudKit.)

`saveTabs` runs 1.5 s after every page finish, deletes every `SavedTab`, and inserts all of them again with their interaction state. On the main context, so it lands on the main thread just as the new page is scrolled. The change-history table has grown to 122,000 rows and is never pruned, so the store is ten times the size of its data.

Necessary? Saving tabs is necessary. Rewriting all of them is not. Update only the tab that changed, insert new ones, delete closed ones, and prune SwiftData history for the device store (or turn history tracking off for it, since nothing reads it). Full save only when the app goes to the background.

### 3. Tab pictures. Memory, and the main thread on the first open of the switcher. (Done the same day: card-sized copies read off the main thread, a ring of twelve; the full picture is dropped once its file is written. Measured: 63 MB after five tab switches.)

Snapshots are taken at 360 points wide, which at 3x is about 1080 by 2340 pixels, around 10 MB decoded each. `keep` holds the decoded image for every tab captured this session, so a session that touched 20 tabs holds about 200 MB in the app process until a memory warning. The switcher reads each tab's JPEG synchronously on the main thread on first access and draws the full image into a card about 180 points wide, and the bar's two thumbnails (22 by 30 points) each hold a full-size image.

Necessary? The pictures are. The resolution is not. Make a card-sized thumbnail off the main thread (`preparingThumbnail`), drop the full decode once the JPEG is written, and load with ImageIO at card size. Keep full size only for the restored-tab stand-in on launch.

### 4. The hiding (cosmetic filter) first answer. Fixed cost on every page. (Done the same day: settled follow-up requests, a sheet per reply, cheaper collapse pass. The Verge went from 12 round trips to 5. The first answer's 620 plus 454 selectors are unchanged.)

Every page's first reply carries about 620 selectors for all sites plus 454 faded cookie selectors, and the same selectors again as `overlays`. Later replies mostly return nothing (0 selectors in 11 of 12 round trips on The Verge) yet each is a round trip to the app, one per animation frame while the DOM grows. Each reply is appended to the same `<style>`, which makes WebKit re-parse the accumulated sheet. `collapsePass` reads `offsetHeight` and `textContent` on every box between 30 and 1200 pixels, every 2 s while the DOM mutates.

Necessary? The approach is right and already far cheaper than letting WebKit test 45k selectors. Trim it: give the page a small hash set of known keys so it only asks when a key can match, debounce later requests to about 150 ms, put each reply in its own `<style>`, and test the ad-like class name before reading `textContent` in `collapsePass`. Worth asking whether the 454 cookie fade selectors need to go to pages with no banner at all.

### 5. History search in the bar. Fine today, scales badly. (Done: an in-memory index of the newest 5,000 pages, built off the main thread; the store is asked only in the moment after launch before it's built.)

`history(matching:)` uses `localizedStandardContains` on title and URL, so a query with few matches scans the whole table on every keystroke, synchronously on the main thread, with no debounce, twice per pause. This phone has 739 entries, so it is cheap now. At 20,000 entries it would be a visible stutter per key (estimate). The 90-day prune caps growth but a heavy user reaches that size.

Necessary? Yes, but as an in-memory index of host, title, and count (the newest few thousand entries), built off the main thread and updated on visit.

### 6. The 30 s live ticker and 1 Hz media reports invalidate the root view. (Done the same day: assign on change only, nothing in the background, time-only media reports dropped.)

`refreshLive` runs every 30 s forever, including in the background during audio, and does two SwiftData fetches. `liveItems` is computed inside the root body, so the whole `BrowserView` re-runs every 30 s, and every second when a background tab plays sound. The web view host's update short-circuits, so this is wasted CPU rather than dropped frames, but it contradicts "0% idle".

Necessary? Store `liveItems` and assign only on change; read it only inside the band; pause the ticker when the band preferences are off or the app is in the background. Report media time on state changes, not every second.

### 7. Answer and summary rendering re-parses all Markdown on every update. (Done the same day: parse cached per text, inline runs cached, streaming coalesced to 40 ms, reading line in steps of a hundredth.)

`page` in `MarkdownText` is computed, and each block's `inline()` reads `kind` twice, so one body run parses the document about 1 + 2 × blocks times. Streaming appends text per SSE event with no throttle, and `readProgress` in `BrowseForMeView` is root state written on every scroll frame, which re-runs the cascade per frame. Estimated 5 to 20 ms per body run on a 30-block answer. This is the most likely cause of stutter while scrolling a long answer.

Necessary? Parse once per text change, cache per block, throttle streamed text to 20 to 30 Hz, and move `readProgress` into a child view.

### 8. Features that cost people who never use them (Done the same day: Reminders gated on being on, Mac sync backs off to a minute and skips idle writes. Today's morning refresh left as is: Today opens itself each morning by default, so the refresh is used. iCloud history: a page seen again within five minutes is no longer written as a new visit; the rest left as is.)

- **Reminders sync** creates an `EKEventStore` in app init and installs observers whether or not sync is on. Return early when it is off.
- **Today's morning refresh** is scheduled for every user; with nothing set up it still fetches weather and runs the on-device model. Gate it on Today having been opened recently.
- **Mac sync (RokoSync)**, when on, polls every 4 s while active, writes the snapshot file and a defaults key every round even when nothing changed, and the defaults write makes `SettingsSync` copy the whole defaults dictionary. Back off (4, 15, 60 s) and skip writes when nothing changed. Off for everyone without a key, so no cost for most.
- **iCloud history**: every page visit becomes a CloudKit export and a silent push to every other device. Consider keeping history on the device, or syncing a coarse digest.
- **Spotlight, widgets, notification updates** are already fingerprinted and cheap; no change needed.

### 9. Small things on the page path (Done the same day: spare web view after didFinish, favicon failures remembered for the session, download progress at 4 Hz, app offer checks the offered set before LaunchServices. The previous tab's snapshot timing was left: it needs the web view still in the window.)

- The spare web view is rebuilt 1 s after one is taken, in the middle of the new page's load. Build it after `didFinish`.
- The previous tab's snapshot is captured at the moment the new tab starts loading. Defer it by a second.
- `offerApp` calls `canOpenURL` before the dedup check on every finished page of a listed site.
- A favicon fetch that fails is never remembered, so such sites refetch on every load. Add a negative cache.
- Download progress updates the UI per network chunk. Throttle to about 4 Hz.
- The 60 ms sleep before selecting the restored tab could be a check for a pending link instead.

## Already good, leave alone

Rule lists compiled once per list version and looked up before the main thread is busy; the hiding indexes decoded in parallel off main; the consent rules kept off the first-paint path; three live tabs with full suspension of the rest; no data detectors; autoplay blocked; JPEG writes off main; the signature short-circuit in `ContentBlocker.apply`; preloading the top hit; the scroll observer and pull gestures in UIKit with transactions disabled; grain from random bytes; debounced saves and suggestions; overlays and Settings built only when shown.

## Suggested order

1. Consent: frame gating, heuristics off, retries down, reports off in Release. Biggest per-page win, a day's work.
2. Incremental tab save plus history pruning. Half a day; removes a main-thread write after every page.
3. Thumbnail-sized snapshots. Half a day; large memory win for people with many tabs.
4. Cosmetic filter: key hash set and debounce. A day.
5. Markdown parse caching and streaming throttle. A day.
6. Ticker and media invalidation. Hours.
7. Gating Reminders, Today, and sync work on feature use. Hours each.

## Done later the same day, beyond the ranked list

Launch housekeeping spread over the first four seconds; the store is never moved aside while the phone is still sealed after a restart; working animations at 30 Hz; widget reloads only on a real weather change; to-do alerts diffed rather than replaced; the bar's progress line as its own view; popular sites' names folded once; the download spare web view released; a timed-out watch stops loading; Notify Me's offscreen view no longer suspended. Left: syncing history to iCloud at all (a product decision), the previous tab's snapshot timing, the favicon store's one version counter (per-host invalidation would need an object per host), and the launcher's material blur over the live page (a design choice).

## Not verified

Costs marked as estimates come from reading code, not from a profiler. The benchmark harness was not re-run on ad-heavy pages (that is still open from October). The Watcher's offscreen web view inherits `inactiveSchedulingPolicy = .suspend` while never being in a window; worth a test that its scripts actually run.
