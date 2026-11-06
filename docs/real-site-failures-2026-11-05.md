# roko on real sites: failures found on 5 November 2026

From the on-phone test of ten browsers (iPhone 17 Pro, iOS 27.2, roko 0.1.2 build 12). Every place roko
did worse than another browser is here, with its cause and what became of it. Results are in the test report.

| # | Kind | Site | What happened | Cause | Status |
|---|------|------|---------------|-------|--------|
| 1 | Cookie wall | Marca | Wall stayed up | Site's own wall, no rule. The accept-if-no-costs-money case only ran after a rule matched | Fixed in general, tested in the simulator |
| 2 | Cookie wall | Corriere | Wall stayed up in the simulator; on the phone see 5 | Same, with its buttons in a small pinned footer inside the wall | Fixed in general, tested in the simulator |
| 3 | Cookie wall | The Telegraph | Wall stayed up | Sourcepoint in a frame on the site's own address, under scrambled names, so roko never sent it the rules | Fixed in general, tested in the simulator |
| 4 | Empty page | BILD | Wall hidden, page empty apart from header and footer | The wall was only hidden, so the page was held back unanswered. Answered and reloaded, it fills in with the ads list on | Fixed in general, first visit tested in the simulator |
| 5 | Crash | Corriere | "This page keeps stopping" on the phone, once | Not yet known. Doesn't happen in the simulator | Open: re-test on the phone |
| 6 | Ad server | Daily Mail | `s0.2mdn.net` reached | `$~media` rules dropped by the list converter | Fixed in general |
| 7 | Late ad | Spiegel | "Anzeige" box arrives at 15.8 s and pushes the page down | Served from Spiegel's own hosts. Not yet known which rule should catch it | Open: re-test after the wall fix |
| 8 | Visible ad | BILD | XXXLutz banner above the page, ads list on | Not yet known. Brave shows a similar one on Welt | Open |
| 9 | Blank photos | CNN | Two photos in the "lead package" slots stayed blank on the phone while Arc, Lens and Brave showed them | Not yet known. Plain images in the page's HTML, shown fine in the simulator | Open: re-test on the phone |
| 10 | Empty box | The Sun | Grey box with the Sun's logo left in the page | The site's own ad slot. Other browsers leave it too, with a label or without. Why the fold-away script missed it isn't known | Open: re-test on the phone |
| 11 | Tracker reached | The Telegraph | `beacon.viafoura.io` reached | Our copy of the lists was ten days old and didn't have it yet | Fixed by refreshing the lists; they need refreshing before each release |

Checked and not roko's:

- **New York Post, black screen for about 20 s in one run.** The site's own stall: Edge hit the same one a minute later. 2 of 40 runs.
- **New York Post, 130 MB in that run.** iOS was downloading from `updates.cdn-apple.com` at the time, and the data counters are for the whole phone.
- **Daily Mail, slow once.** 3.9 s in one round, 1.2 s in the other two.
- **`www.googletagmanager.com` on The Independent, `cdn.optimizely.com` on CNN, `tags.tiqcdn.com` on The Sun.** EasyPrivacy lets these through on purpose on those sites, or doesn't list them, to keep the pages working. Brave reaches the same ones. Left alone.

