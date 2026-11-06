# Real sites on a real iPhone

The test behind `docs/real-site-test-2026-11-05.md`. A UI test on the phone opens each page in each
browser and records the screen and the phone's network counters; a USB mirror of the phone's traffic
says which servers each browser reached. No page contents are kept, only hostnames and timing.

1. Install the browsers. Build `runner/` with xcodegen, signed with your team, into `$REAL_WORK/real/dd`.
2. `DEVICE=<id> zsh tools/capture.sh`, typing your password: the traffic log, over USB.
3. `python3 -I tools/plan.py <name> <seconds> <seed> <scrolls> <dump> site,site... [browser,browser...] > $REAL_WORK/real/work/plan-<name>.json`
4. `DEVICE=<id> zsh tools/all.sh <name>`, with Screen Time off and the phone unlocked. The phone may ask
   for its passcode when automation mode starts, each prompt lasting a minute.
5. `tools/analyse.py <pass folder>...` gives seconds and data per run. `hosts.py` turns captures into the
   log `narrow.py` reads, with Peter Lowe's list and Disconnect's in `lists/`. `sheet.py` makes screenshot
   sheets. These hold private things from the phone's screen, such as notifications: don't publish them.

Runs on real sites differ day to day, so compare browsers within one pass.
