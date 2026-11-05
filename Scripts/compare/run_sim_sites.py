#!/usr/bin/env python3
"""Data Safari and roko pull from ad-heavy sites in the simulator, from nettop's per-process
counters on the Mac, so no iPhone is involved and Safari has no content blocker.
Usage: Scripts/compare/run_sim_sites.py <device> [rounds] [seconds]"""
import csv, io, statistics, subprocess, sys, time, urllib.parse
device, rounds, seconds = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 2, int(sys.argv[3]) if len(sys.argv) > 3 else 35
sites = {"dailymail": "https://www.dailymail.co.uk/home/index.html", "thesun": "https://www.thesun.co.uk/", "forbes": "https://www.forbes.com/", "index.hr": "https://www.index.hr/"}
apps = {"safari": "com.apple.mobilesafari", "roko": "com.growthstudio.roko"}
def counters():
    """Bytes received per web networking process in the simulator; the Mac's own WebKit apps don't count."""
    ps = subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True).stdout
    pids = {line.split()[0] for line in ps.splitlines() if "SimulatorRuntime" in line and "WebKit.Networking" in line}
    out = subprocess.run(["nettop", "-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"], capture_output=True, text=True).stdout
    total = {}
    for row in csv.reader(io.StringIO(out)):
        if len(row) > 2 and row[1].isdigit() and row[0].rsplit(".", 1)[-1] in pids:
            total[row[0]] = int(row[1])
    return total
results = {}
for round_ in range(rounds):
    for site, url in sites.items():
        for browser, bundle in apps.items():
            for b in apps.values():
                subprocess.run(["xcrun", "simctl", "terminate", device, b], capture_output=True)
            time.sleep(3)
            before = counters()
            target = url if browser == "safari" else "roko://open?url=" + urllib.parse.quote(url, safe="")
            subprocess.run(["xcrun", "simctl", "openurl", device, target], capture_output=True)
            time.sleep(seconds)
            after = counters()
            mb = sum(v - before.get(k, 0) for k, v in after.items()) / 1e6
            results.setdefault((site, browser), []).append(mb)
            print(f"round {round_ + 1} {site:10} {browser:8} {mb:8.2f} MB", flush=True)
print()
for site in sites:
    s, r = results[(site, "safari")][0], results[(site, "roko")][0]
    print(f"{site:10} first visit: safari {s:7.2f} MB   roko {r:7.2f} MB   roko saves {100 * (1 - r / max(s, .01)):5.1f}%")
