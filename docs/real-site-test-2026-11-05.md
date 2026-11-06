# roko on real sites: ten browsers on one iPhone

iPhone 17 Pro, iOS 27.2, 5 to 6 November 2026. roko 0.1.2 (12) against Safari, Chrome, Firefox, Edge, Brave,
DuckDuckGo, Arc, Lens and Quiche, on real sites over the same Wi-Fi. A test on the phone opens each page in
each browser, in a random order per site, and records the screen. A USB mirror logs which servers were
reached. Tool: `Scripts/compare/real-sites`. Failures and what became of them:
`docs/real-site-failures-2026-11-05.md`.

## Speed

Time until half of the page's content is drawn as it ends up, over 24 runs per browser on eight ad-heavy
sites (CNN, Daily Mail, The Guardian, The Independent, Index.hr, New York Post, The Sun, Wikipedia), all
return visits. Median seconds:

| Browser | Half drawn | 80% drawn |
|---|---|---|
| roko | 1.07 | 1.22 |
| Quiche | 1.70 | 1.70 |
| Lens | 2.76 | 2.92 |
| Arc | 3.41 | 3.41 |
| Firefox | 3.47 | 3.54 |
| Brave | 3.54 | 4.20 |
| DuckDuckGo | 4.33 | 4.38 |
| Chrome | 4.96 | 4.96 |
| Safari | 4.96 | 5.22 |
| Edge | 5.46 | 5.46 |

roko was the fastest browser in 15 of the 24 site rounds. Its median per site, against the best other browser:

| Site | roko | Best other |
|---|---|---|
| Wikipedia | 0.48 | Quiche 0.73 |
| The Guardian | 0.49 | Quiche 1.77 |
| The Sun | 0.71 | Quiche 1.11 |
| The Independent | 0.96 | Arc 2.87 |
| Daily Mail | 1.21 | Quiche 1.56 |
| New York Post | 2.37 | Brave 3.88 |
| Index.hr | 1.41 | **Quiche 0.83** |
| CNN | 7.14 | **DuckDuckGo 4.64** (Arc 4.87, Edge 6.67, Chrome 6.80, Firefox 6.82, Safari 6.90) |

A fourth round, on a later build and four browsers: roko 0.90, Quiche 1.46, Brave 3.30, Safari 3.62.

**Where roko didn't lead.** On a first visit to eight other sites, most behind cookie walls, roko's median was
3.68 s, behind Safari (2.65), Lens (2.84), Quiche (2.88), Chrome (3.12), Firefox (3.20) and Arc (3.31). A browser
counts as drawn once its wall shows, which favours those that leave the wall up, and two of roko's runs were
the failures since fixed. It still means the speed result is for return visits. On a second visit to those
sites roko led with 1.80 s (Quiche 2.59, Firefox 3.15, Lens 3.83, Safari 3.98).

## Ad and tracker servers reached

Per page, over 40 runs per browser, page traffic only. A server counts if Peter Lowe's list or Disconnect's says
so (lists roko doesn't draw on), leaving out cookie consent tools. Mean:

| roko | Arc | Brave | DuckDuckGo | Quiche | Firefox | Safari | Edge | Lens | Chrome |
|---|---|---|---|---|---|---|---|---|---|
| 0.7 | 0.9 | 1.7 | 2.7 | 4.2 | 5.7 | 5.7 | 9.8 | 16.4 | 16.4 |

Different servers in all: roko 10, Arc 9, Brave 25, DuckDuckGo 34, Safari 57, Firefox 76, Quiche 96, Edge 100,
Chrome 141, Lens 151. A browser stopped at a wall reaches fewer, and Arc often was.

## Clean after scrolling

Six ad-heavy pages (CNN, Daily Mail, The Guardian, The Independent, New York Post, The Sun), five swipes, scored by
eye: no visible ad, pop-up or wall. roko 6, Brave 3, DuckDuckGo 3, Lens 3, Quiche 2, Arc 2, Firefox 1, Safari 0,
Chrome 0, Edge 0. One pass, one person's eye, and a walled browser can't be judged on ads.

## Cookie walls

First visit to eight European sites, scored by eye. Past the wall: Brave 6, roko 4, Arc 1, the others 0. In roko's
other two runs the page broke. Those failures are fixed and all eight now get past the wall on the phone, but on
visits with an answer already stored, so this hasn't been measured again from a true first visit. Where the only
other way past a wall costs money, roko accepts it, with ads and trackers still blocked.

## Data

Not a lead for roko. Median MB per run in a 20 s window: Quiche 0.4, Firefox 1.2, roko 1.4, Brave 1.5, DuckDuckGo 1.8,
Lens 2.0, Edge 2.0, Chrome 2.0, Arc 2.3, Safari 2.4. Totals over the three rounds: Brave 56, Quiche 64, roko 81, others 87 to
146. roko was high on CNN (8.8 against 2.1 for Chrome). The counters are for the whole phone, and iOS was
downloading an update during part of the test, so these are rough.

## What to keep in mind

- Return visits with warm caches, so this is not a first-load test.
- The phone was thermally "serious" for 426 of 432 runs, on charge, alike for all browsers.
- The first two rounds used the same browser order for each site, by a mistake in the plan. The third and fourth didn't.
- 24 runs per browser, on one phone, one network, over one night.
- These runs were on build 12. Fixes since then haven't had a round against all ten browsers.
