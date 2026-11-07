# roko and Brave on sites neither had opened: clean pages, second round

iPhone 17 Pro, 7 November 2026, 11:36 to 12:15, same Wi-Fi. roko 0.1.4 at `59bd559`, with the day's fixes for scroll locks and
consent walls, against Brave 1.98. 16 new sites chosen before any run, none used in an earlier test. One first visit each: 20
seconds, then five swipes. Brave's runs were kept at least 99 seconds apart, so its restore-tabs dialog didn't come up. All 48
runs loaded and none failed.

Scored as in the first round (`docs/real-site-test-2026-11-07-clean.md`): frames cropped, shuffled and lettered, and scored by a
reader that wasn't told which browser was which. Clean means the real page, scrolling, with no ad, consent wall, pop-up or
anything pinned over it in any frame.

## Result

**roko 9 of 16, Brave 9 of 16: a tie.** With the first round (roko 7, Brave 6) that's roko 16 and Brave 15 of 32 sites.

| Site | roko | Brave |
|---|---|---|
| NBC News | clean | clean |
| 20 Minutes | clean | clean |
| La Dépêche | clean | clean |
| LA Times | clean | clean |
| il Giornale | clean | clean |
| Merkur | clean | clean |
| elDiario.es | clean | clean |
| Sky News | clean | clean |
| RTL Nieuws | clean | DPG consent wall |
| RP Online | **pay-or-consent wall, page never shows** | clean |
| WP.pl | **pay-or-consent wall, page stuck** | the same wall, and an ad |
| Tagesspiegel | subscribe overlay, **"Anzeige" ads** | subscribe overlay |
| Daily Star | the site's own bar pinned at the bottom, an "AD FEATURE" tile | the site's own bar |
| El Periódico | a sponsored brand piece | the same |
| CBS News | the site's own live player pinned | the same |
| oe24 | the site's own live-stream bar | the same |

The last three rows are the site's own content pinned or sponsored, the same in both.

## What this found in roko

- **RP Online:** its "Weiter mit Werbung" (continue with ads) or RP+ wall stayed up, and the page never showed. Brave got past it.
- **WP.pl:** its "Odrzucam zgody i płacę" (reject and pay) wall stayed up in both browsers.
- **Tagesspiegel:** two ads labelled "Anzeige" showed in roko and not in Brave.

Screenshots hold private things from the phone's screen and aren't published.
