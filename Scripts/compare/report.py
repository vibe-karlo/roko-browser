#!/usr/bin/env python3
"""Reads results.jsonl. Link to page: the first report after each start, since a browser
restoring earlier test tabs reports those again later. Blocking: out of the hosts that any
browser reached, as one browser's filter (a Safari content blocker) makes a poor baseline.
With --latest the newest score per browser is used, which is also the default for reruns."""
import json, pathlib, statistics
rows = [json.loads(l) for l in open(pathlib.Path(__file__).parent / "results.jsonl")]
starts = {}
times = {}
for r in rows:
    key = (r["b"], r["r"])
    if r.get("kind") == "start":
        starts[key] = r["at"]
        times.pop(key, None)
    elif r.get("kind") == "loaded" and key in starts and key not in times:
        times[key] = r["at"] - starts[key]
for browser in sorted({k[0] for k in times}):
    t = [v for k, v in times.items() if k[0] == browser]
    print(f"{browser:12} link to page: median {statistics.median(t):5.2f} s, best {min(t):5.2f}, worst {max(t):5.2f}, runs {len(t)}")
scores = {r["b"]: r for r in rows if r.get("kind") == "score"}
live = sorted({h for r in scores.values() for h, ok in r["seen"].items() if ok is True})
groups = next(iter(scores.values()))["groups"] if scores else {}
print(f"\n{len(live)} hosts reached by at least one browser")
web = [h for h in live if groups.get(h) != "OEMs"]
for browser, r in sorted(scores.items(), key=lambda x: -sum(x[1]["seen"].get(h) is not True for h in live)):
    blocked = [h for h in live if r["seen"].get(h) is not True]
    wb = [h for h in web if r["seen"].get(h) is not True]
    print(f"{browser:12} all {len(blocked):3}/{len(live)} = {100 * len(blocked) / max(len(live), 1):5.1f}%   without phone-maker hosts {len(wb):3}/{len(web)} = {100 * len(wb) / max(len(web), 1):5.1f}%")
