# First visits: time to a readable page

iPhone 17 Pro, 7 November 2026, 12:44 to 13:20, same Wi-Fi. roko 0.1.4 at `485b903` against Safari, Lens, Quiche, Chrome, Firefox
and Arc, the six browsers that drew first-visit pages sooner than roko on 5 November (`docs/real-site-test-2026-11-05.md`). 12 sites
none of them had opened, chosen before any run. One run each, 20 seconds, in a random browser order per site. All 84 runs loaded.

## What counts

The earlier first-visit test timed how soon the screen settled. A browser stopped at a cookie wall settles at once, on the wall, and
scored as fast. This test counts only a readable page: each run's last screen was judged by a reader that wasn't told which
browser was which, or what we hoped for. A run whose last screen was a wall, a dialog over most of the page, a bot check or a blank
screen didn't reach a readable page. For the rest, the time is when half of that last screen was drawn, from the first frame the
browser showed.

## Result

| Browser | Readable page reached, of 12 | Median time, when reached | First to a readable page, of 10 sites any reached |
|---|---|---|---|
| roko | **10** | **1.23 s** | **7** |
| Arc | 9 | 1.84 s | 2 |
| Lens | 5 | 2.98 s | 0 |
| Quiche | 5 | 1.33 s | 0 |
| Firefox | 5 | 1.36 s | 1 |
| Safari | 3 | 1.92 s | 0 |
| Chrome | 3 | 2.97 s | 0 |

Counting a page that never became readable as never, roko's median over all 12 sites is 1.57 s and Arc's 2.69 s. The other five
reached a readable page on 5 sites or fewer, so their median over all 12 is "never".

Per site, seconds to half drawn. An x means the last screen wasn't readable:

| Site | roko | Safari | Lens | Quiche | Chrome | Firefox | Arc |
|---|---|---|---|---|---|---|---|
| ABC (Australia) | 1.76 | 6.91 | 3.37 | 3.05 | 3.68 | 2.69 | 3.05 |
| AP News | 2.31 | 6.61 x | 2.98 | 5.54 x | 6.38 x | 9.44 x | 3.15 |
| Axios | 1.37 | 1.30 | 3.77 | 1.33 | 2.97 | 1.25 | 1.84 |
| Die Presse | 0.76 x | 1.27 x | 1.54 x | 1.56 x | 1.64 x | 1.62 x | 0.77 x |
| Europe 1 | 3.39 | 2.24 x | 1.25 x | 1.08 x | 1.77 x | 0.86 x | 0.85 |
| Hindustan Times | 0.48 | 6.26 x | 4.05 x | 2.90 x | 5.52 x | 1.23 | 2.33 |
| Il Mattino | 0.85 | 7.74 x | 0.99 | 1.07 | 8.45 x | 7.89 x | 10.94 x |
| Il Post | 0.71 | 1.44 x | 1.47 x | 1.36 x | 1.66 x | 1.18 x | 0.75 |
| Kurier | 3.83 x | 2.99 x | 1.29 x | 1.48 x | 1.39 x | 1.49 x | 6.00 x |
| LCI | 1.09 | 1.25 x | 1.72 x | 1.87 x | 1.87 x | 1.61 x | 0.92 |
| NOS | 1.09 | 1.92 | 1.80 | 1.32 | 2.10 | 1.36 | 1.48 |
| NZ Herald | 1.91 | 5.16 x | 5.90 x | 2.56 | 6.21 x | 2.09 | 3.19 |

## Limits and what it found

- One run per site and browser, and one reader. Among pages every browser could read (ABC, Axios, NOS), roko was first on two and
  Firefox on Axios, by 0.12 s.
- **Die Presse** stopped every browser at a pay-or-accept wall. roko should answer one like that, and didn't.
- **Kurier** stayed behind a consent wall in roko. The reader marked every browser not readable there.
- The other browsers' versions weren't recorded.

Screenshots hold private things from the phone's screen and aren't published.
