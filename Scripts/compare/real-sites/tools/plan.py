#!/usr/bin/env python3
"""Makes a pass's plan. Every site goes through every browser before the next site, in a new
random browser order each time, so network drift and heat land on all browsers alike.
Usage: plan.py <name> <seconds> <seed> <scrolls> <dump 0|1> site,site..."""
import json, random, sys, urllib.parse
BROWSERS = {"safari": "com.apple.mobilesafari", "roko": "com.growthstudio.roko", "brave": "com.brave.ios.browser", "duckduckgo": "com.duckduckgo.mobile.ios", "firefox": "org.mozilla.ios.Firefox", "chrome": "com.google.chrome.ios", "edge": "com.microsoft.msedge", "arc": "company.thebrowser.ArcMobile2", "lens": "com.angelakismax.browser", "quiche": "org.quiche.Browser"}
SITES = json.load(open(__file__.rsplit("/", 1)[0] + "/sites.json"))
name, seconds, seed, scrolls, dump, sites = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5] == "1", sys.argv[6].split(",")
only = sys.argv[7].split(",") if len(sys.argv) > 7 else list(BROWSERS)
rng = random.Random(seed)
plan = []
for site in sites:
    order = list(only)
    rng.shuffle(order)
    for b in order:
        url = SITES[site]
        if b == "roko":
            url = "roko://open?url=" + urllib.parse.quote(url, safe="")
        item = {"id": f"{name}.{site}.{b}", "b": b, "bundle": BROWSERS[b], "url": url, "seconds": seconds}
        if scrolls: item["scrolls"] = scrolls
        if dump: item["dump"] = True
        plan.append(item)
json.dump(plan, sys.stdout)
