#!/usr/bin/env python3
"""Reads sites.jsonl: megabytes the phone received per browser and site, the newest run of
each, with the idle baseline shown beside them."""
import json, pathlib
latest = {}
for line in open(pathlib.Path(__file__).parent / "sites.jsonl"):
    r = json.loads(line)
    latest[(r["site"], r["b"])] = r
idle = [r["in"] / 1e6 for k, r in latest.items() if k[1] == "idle" and "in" in r]
print("idle windows, MB:", " ".join(f"{v:.2f}" for v in idle))
for site in sorted({k[0] for k in latest if k[1] != "idle"}):
    print(f"\n{site}")
    rows = sorted((r["in"] / 1e6, k[1]) for k, r in latest.items() if k[0] == site and "in" in r)
    for mb, browser in rows:
        print(f"  {browser:12}{mb:8.2f} MB")
    print("  skipped:", [k[1] for k, r in latest.items() if k[0] == site and "skipped" in r])
