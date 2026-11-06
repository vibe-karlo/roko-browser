# roko on real sites: failures found on 5 November 2026

From the on-phone test of ten browsers (iPhone 17 Pro, iOS 27.2, roko 0.1.2 build 12). Every place roko
did worse than another browser is here, with its cause and what became of it. Results are in the test report.

| # | Kind | Site | What happened | Cause | Status |
|---|------|------|---------------|-------|--------|
| 1 | Cookie wall | Marca | Wall stayed up | Site's own wall, no rule. The accept-if-no-costs-money case only ran after a rule matched | Fixed, confirmed on the phone |
| 2 | Cookie wall | Corriere | Wall stayed up | Same, with its buttons in a pinned footer inside the wall. On a 17 Pro that 174 px footer passes as "big", so the wall box above it was never checked, which is why the Pro Max simulator didn't show it | Fixed, confirmed on the phone |
| 3 | Cookie wall | The Telegraph | Wall stayed up | Sourcepoint in a frame on the site's own address, under scrambled names, so roko never sent it the rules | Fixed, confirmed on the phone |
| 4 | Empty page | BILD | Story for 5 s, then the site's "because of your ad blocker" wall, then an empty page | Its real anti-adblock, set by `"adBlockWallEnabled":true` in the page. The first diagnosis (an unanswered wall) was wrong: the simulator looked fixed only because its settings had ads allowed on m.bild.de | Fixed with uBlock Origin's site rule, ads still blocked, confirmed on the phone |
| 5 | Crash | Corriere | "This page keeps stopping" every time on the phone | The web process reached iOS's 2,052 MB limit about a second after roko released the page's scroll lock (`body` fixed, 684 px) with the wall still up. Its hide rules matched plain page parts, which was taken as proof an overlay had gone. Found by switching parts of roko off on the phone | Fixed in general, confirmed on the phone, with a safety net for any page that crashes twice |
| 6 | Ad server | Daily Mail | `s0.2mdn.net` reached | `$~media` rules dropped by the list converter | Fixed in general |
| 7 | Late ad | Spiegel | "Anzeige" box arrives at 15.8 s and pushes the page down | Served from Spiegel's own hosts. Cause not established | Not seen in 2 re-tests on the phone; not known to be fixed |
| 8 | Visible ad | BILD | XXXLutz banner above the page, ads list on | Not established | Not seen in 2 re-tests on the phone; not known to be fixed |
| 9 | Blank photos | CNN | Two photos in the "lead package" slots stayed blank on the phone while Arc, Lens and Brave showed them | Not established | Not seen in 3 re-tests; a fourth had one photo still blank at a swipe, which may be lazy loading. Open |
| 10 | Empty box | The Sun | Grey box with the Sun's logo left in the page | The site's own ad slot; a grey box with the logo is also how its images look while loading | Not seen in the last re-test. Open: may be fixed by #13 |
| 11 | Tracker reached | The Telegraph | `beacon.viafoura.io` reached | Our copy of the lists was ten days old and didn't have it yet | Fixed by refreshing the lists; they need refreshing before each release |
| 12 | Link covered | Any | A link from another app on the day's first launch opened under Today | Today opened on launch regardless of the link. Found on Le Monde in the re-test | Fixed in general, tested in the simulator only: the phone had already shown Today that day |
| 13 | Empty box | Marca, Welt | "Publicidad" strip stuck at the bottom; grey box at the top of the page | Slots holding their own script or style, which the fold-away script counted as text a reader could want, and a close button's hidden words | Fixed in general, confirmed on the phone |
| 15 | Data, wall | The Mirror | 12 to 13 MB where Brave used 2, and in some runs its wall stays up | Ad-Shield reloads its ads through its own hosts, with videos. Blocking its host only moves it to another (html-load.com, then magicalblouse.com), and blocking its addresses brings up "Please allow ads" over a blank page, so both were undone. Why the wall sometimes stays isn't known | Open |
| 16 | Visible ad | Focus | An "Anzeige" strip at the bottom and a sponsored box in the page, once its wall is answered | Not established | Open |
| 17 | Cookie wall | Corriere dello Sport, L'Express | roko pressed the no, landing on a subscription offer and an account form ("Disagree and create account") | An account isn't recognised as a price on no. Why Corriere dello Sport's "Rifiuta e abbonati" wasn't caught isn't known | Open |
| 18 | Cookie wall | AS, Repubblica, Il Messaggero | Wall stayed up or the no was pressed | "Deny & surf ad-free" and "Rifiuta e abbonati" weren't read as a price on no, a linked word was pressed as yes, and a wall asking twice got one press | Fixed in general, confirmed on the phone on repeat visits |
| 14 | Slow | Daily Mail | 3.2 to 3.9 s in some rounds, 1.2 s in others | In a slow run the page commits, paints nothing, and navigates again with 1 s to its first byte; a quick run commits once. It looks like the site's own bounce (Quiche had 3.21 s once too), not proven | Not roko's as far as known |

Checked and not roko's:

- **New York Post, black screen for about 20 s in one run.** The site's own stall: Edge hit the same one a minute later. 2 of 40 runs.
- **New York Post, 130 MB in that run.** iOS was downloading from `updates.cdn-apple.com` at the time, and the data counters are for the whole phone.
- **Marca with no styling, 6 November from about 09:10.** Marca's own fault: its phone page came with the wrong stylesheet (`main-cover` instead of `main-cover-mobile`). A plain Chromium browser, Safari and Firefox showed the same page. Brave and DuckDuckGo showed it styled, for a reason not established.
- **`www.googletagmanager.com` on The Independent, `cdn.optimizely.com` on CNN, `tags.tiqcdn.com` on The Sun.** EasyPrivacy lets these through on purpose on those sites, or doesn't list them, to keep the pages working. Brave reaches the same ones. Left alone.

