# roko on real sites: the four closest browsers

iPhone 17 Pro, 7 November 2026, 00:51 to 02:08, same Wi-Fi. roko at commit `763ad75` (Release, shown as 0.1.3 (16)) against
Quiche, Lens, Arc and Brave, the closest in `docs/real-site-test-2026-11-05.md`. Same tool, same eight sites. Nothing failed:
all 190 runs finished, in one attempt per pass. Runs on real sites differ day to day, so compare browsers within this test,
not with the earlier numbers.

## Speed

Time until half of the page's content is drawn as it ends up, over 24 return visits per browser (three rounds of eight
sites, after one warm-up round that isn't counted). Median seconds:

| Browser | Half drawn | 80% drawn |
|---|---|---|
| roko | 0.77 | 0.83 |
| Quiche | 1.48 | 1.52 |
| Arc | 2.87 | 2.87 |
| Lens | 2.91 | 2.91 |
| Brave | 3.75 | 3.88 |

roko was the fastest browser in 21 of the 24 site rounds, Quiche in the other 3. Median per site:

| Site | roko | Quiche | Lens | Arc | Brave |
|---|---|---|---|---|---|
| CNN | 1.53 | 14.79 | 3.47 | 3.13 | 13.67 |
| Daily Mail | 1.26 | 1.58 | 1.67 | 1.62 | 3.11 |
| The Guardian | 0.48 | 1.28 | 1.60 | 2.70 | 4.22 |
| The Independent | 0.48 | 2.50 | 2.97 | 1.76 | 2.77 |
| Index.hr | 1.05 | 1.10 | 5.92 | 3.33 | 7.96 |
| New York Post | 2.85 | 10.25 | 8.58 | 9.04 | 4.62 |
| The Sun | 0.71 | 0.98 | 2.96 | 3.18 | 2.82 |
| Wikipedia | 0.48 | 0.60 | 0.86 | 1.45 | 1.99 |

roko now leads on all eight sites, including the two it lost on 5 November (CNN and Index.hr). Index.hr is close: 1.05 against 1.10.

## Ad and tracker servers reached

Per page, over 32 runs per browser, page traffic only, counted as in the earlier report. Mean:

| Quiche | roko | Arc | Brave | Lens |
|---|---|---|---|---|
| 0.3 | 0.7 | 1.2 | 1.4 | 16.7 |

**roko is not lowest here: Quiche is.** A browser stopped at a wall reaches fewer servers, and the screenshots below show Quiche
and Arc behind walls on several of these sites, which may explain it. That is not measured. This test only has return visits
to eight sites, so it can't be set against Quiche's 4.2 in the earlier, wider test.

## Clean while scrolling

Six ad-heavy sites, one frame at the second of five swipes, scored by eye: no visible ad, pop-up or wall. One pass, one reader,
and one frame per run, so a rough guide.

| Browser | Clean | Stopped by |
|---|---|---|
| roko | 6 of 6 | |
| Brave | 3 | The Guardian's support box, The Independent's offer, a Google sign-in sheet on the New York Post |
| Quiche | 2 | Consent walls on CNN, The Guardian, The Independent; the New York Post's ad blocker wall |
| Lens | 2 | Consent walls on The Guardian, The Independent, The Sun; the New York Post's ad blocker wall |
| Arc | 2 | The Guardian's and The Sun's consent walls, The Independent's offer, the New York Post's ad blocker wall |

## Limits

- The phone's own allowed sites were left as they were. None of the eight sites is on that list.
- The other browsers' versions weren't recorded.
- `763ad75` isn't the final build: six smaller performance fixes come after it. Re-run roko alone if they could change speed.
- Screenshots hold private things from the phone's screen, such as a to-do line, and aren't published.
