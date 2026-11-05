#!/usr/bin/env python3
"""Reads results.jsonl: link to page per browser, and hosts blocked out of those Safari reached."""
import json, pathlib, statistics
rows = [json.loads(l) for l in open(pathlib.Path(__file__).parent / "results.jsonl")]
starts = {(r["b"], r["r"]): r["at"] for r in rows if r.get("kind") == "start"}
for browser in sorted({r["b"] for r in rows}):
    times = [r["at"] - starts[(browser, r["r"])] for r in rows if r["b"] == browser and r.get("kind") == "loaded" and (browser, r["r"]) in starts]
    if times:
        print(f"{browser:12} link to page: median {statistics.median(times):.2f} s, best {min(times):.2f}, worst {max(times):.2f}, runs {len(times)}")
scores = {r["b"]: r for r in rows if r.get("kind") == "score"}
base = scores.get("safari")
if base:
    live = [h for h, ok in base["seen"].items() if ok is True]
    print(f"\n{len(live)} hosts reached by Safari, of {len(base['seen'])}")
    for browser, r in sorted(scores.items()):
        blocked = [h for h in live if r["seen"].get(h) is not True]
        print(f"{browser:12} blocked {len(blocked)}/{len(live)} = {100 * len(blocked) / max(len(live), 1):.1f}%")
    roko = scores.get("roko")
    if roko:
        print("\nroko let through:", *[h for h in live if roko["seen"].get(h) is True], sep="\n  ")
