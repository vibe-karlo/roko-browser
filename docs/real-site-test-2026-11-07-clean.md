# roko and Brave on sites neither had opened: clean pages

iPhone 17 Pro, 7 November 2026, same Wi-Fi. roko 0.1.4 (17) against Brave 1.98, on 16 sites chosen before any run and not used
in an earlier test. One first visit each: 20 seconds, then five swipes, six frames in all.

The frames were cropped, shuffled and lettered, then scored by a reader that wasn't told which browser was which or what we hoped
for. Clean means the real page shows, with no ad, consent wall, pop-up or anything pinned over it, in any frame. One run per site
and one reader, so a small test.

## Result

**roko 7 of 16, Brave 6 of 16. That's effectively a tie**, and it doesn't support a claim that roko is cleanest.

| Site | roko | Brave |
|---|---|---|
| Metro | clean | clean |
| La Vanguardia | clean | clean |
| USA Today | clean | clean |
| Fox News | clean | clean |
| n-tv | clean | clean |
| GB News | clean | pay-or-consent wall |
| Il Fatto Quotidiano | clean | empty strip with a close button pinned at the top |
| AD | DPG consent wall | clean |
| People | **page won't scroll** | consent wall |
| NU.nl | DPG consent wall | sponsored tile |
| El Mundo | sponsored box | sponsored box |
| Die Zeit | subscribe sheet | subscribe sheet |
| TGCOM24 | sponsored block, floating player | sponsored block, floating player |
| Le Parisien | floating player | floating player |
| weather.com | app prompt | app prompt |
| Le Point | bot check | bot check |

Brave's strip on Il Fatto Quotidiano is the narrowest call: it covers little and holds no ad. Forgive it and the score is 7 to 7.

Cookie walls alone also tie: two stayed up in each browser, and they were different ones. The bot check on Le Point stopped both.

## What this found in roko

- **People doesn't scroll.** The reader scored it clean because no wall showed, but all six frames were the same. It happens again in
  the simulator on this build, so we changed the score to not clean by hand. The cause isn't established.
- **DPG Media's consent wall stays up** on AD and NU.nl. Brave gets past it on both.

## Test faults

- Force-closed and reopened within about a minute, Brave asks whether to restore its tabs and doesn't load the page. That spoiled 5
  of its 16 runs (n-tv, TGCOM24, NU.nl, Fox News, weather.com), which showed 27 to 291 KB of data. They don't count against Brave.
- Two attempts to redo them failed the same way: visits to warm Brave up, and having the tool answer the dialog. They don't count either.
- The third attempt left over two minutes between runs, and all five loaded (1.7 to 19 MB). They ran about 30 minutes after the rest.
  Brave had already had Fox News and weather.com on screen in the spoiled runs, so those two weren't strictly first visits for it.
- Each of Brave's 48 runs in the two speed tests loaded more than 400 KB, so this dialog doesn't appear to have affected those numbers.

Screenshots hold private things from the phone's screen, such as a to-do line, and aren't published.
