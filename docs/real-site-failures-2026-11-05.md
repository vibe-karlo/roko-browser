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
