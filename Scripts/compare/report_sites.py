#!/usr/bin/env python3
"""Reads sites.jsonl: per site and browser, data downloaded, servers contacted, and how
many of those are on EasyList or EasyPrivacy's plain host lists (Browser/Resources/Blocklists)."""
import collections, json, pathlib
here = pathlib.Path(__file__).parent
lists = here.parent.parent / "Browser/Resources/Blocklists"
ads = {l.strip() for name in ("ads-hosts.txt", "privacy-hosts.txt") for l in open(lists / name) if l.strip()}
def listed(host):
    parts = host.split(".")
    return any(".".join(parts[i:]) in ads for i in range(len(parts) - 1))
runs = collections.defaultdict(list)
for line in open(here / "sites.jsonl"):
    row = json.loads(line)
    if "/" in row["label"]:
        runs[row["label"]].append(row)
for site in sorted({k.split("/")[1] for k in runs}):
    print(f"\n{site}\n{'browser':12}{'MB down':>9}{'servers':>9}{'ad/tracker':>12}{'connections':>13}")
    rows = sorted(((k.split("/")[0], v) for k, v in runs.items() if k.endswith("/" + site)), key=lambda x: sum(r["down"] for r in x[1]))
    for browser, conns in rows:
        hosts = {r["host"] for r in conns}
        print(f"{browser:12}{sum(r['down'] for r in conns) / 1e6:9.2f}{len(hosts):9}{sum(listed(h) for h in hosts):12}{len(conns):13}")
