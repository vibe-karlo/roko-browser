#!/usr/bin/env python3
# Ad and tracker hosts per browser, without consent tools, page traffic only.
import collections, json, pathlib, re, sys, statistics, bisect
L = pathlib.Path(sys.argv[1]); W = pathlib.Path(sys.argv[2]); passes = sys.argv[3:]
pgl = {l.strip().lower() for l in open(L / "pgl.txt") if l.strip() and not l.startswith("#")}
disc = set(); dj = json.load(open(L / "disconnect.json"))
for cat, entries in dj["categories"].items():
    if cat == "Content": continue
    for e in entries:
        for company in e.values():
            for site, ds in company.items():
                if isinstance(ds, list): disc.update(d.lower() for d in ds)
CONSENT = ("cookielaw.org","onetrust.com","privacy-mgmt.com","privacy-center.org","privacymanager.io","consensu.org","cookiebot.com","didomi.io","trustarc.com","usercentrics.eu","sourcepoint.com")
def hit(n, t):
    p = n.split("."); return any(".".join(p[i:]) in t for i in range(len(p)-1))
def consent(n): return any(n == c or n.endswith("."+c) for c in CONSENT)
addr = {}; rows = []
for line in open(W/"hall.jsonl"):
    r = json.loads(line)
    if r["via"] == "answer": addr[r["addr"]] = r["name"]; continue
    rows.append(r)
rows.sort(key=lambda r:r["t"]); ts=[r["t"] for r in rows]
out=collections.defaultdict(lambda: collections.defaultdict(list)); first=collections.defaultdict(collections.Counter); own=collections.defaultdict(collections.Counter)
tot=collections.defaultdict(list)
for ps in passes:
    for line in open(W/"passes"/ps/"log.jsonl"):
        r=json.loads(line)
        if "b" not in r: continue
        start=r["at"]+2.5; end=start+r["frames"]/max(r["fps"],.1)
        a,z=bisect.bisect_left(ts,start),bisect.bisect_right(ts,end)
        owners=collections.Counter()
        for x in rows[a:z]:
            if x.get("p","") and x["p"].startswith("com.apple.WebKit") and x.get("e"): owners[x["e"]]+=1
            elif x.get("e") and x.get("p")==x.get("e"): owners[x["e"]]+=0
        owner=owners.most_common(1)[0][0] if owners else None
        names=set(); ownnames=set()
        for x in rows[a:z]:
            if x["via"] not in ("sni","quic"): continue
            n=x.get("name") or addr.get(x.get("dst"))
            if not n: continue
            web = x.get("p","") and x["p"].startswith("com.apple.WebKit") and x.get("e")==owner
            # Chromium and Gecko run their own network stack in the app process.
            nonwk = r["b"] in ("chrome","edge","firefox","brave") and x.get("e")==owner
            if web or nonwk: names.add(n)
        ads={n for n in names if (hit(n,pgl) or hit(n,disc)) and not consent(n)}
        tot[r["b"]].append(len(ads))
        for n in ads: first[r["b"]][n]+=1
for b,v in sorted(tot.items(),key=lambda a:statistics.mean(a[1])):
    print(f"{b:11s} runs {len(v):3d}  mean {statistics.mean(v):5.1f}  median {statistics.median(v):4.1f}  distinct {len(first[b])}")
print("\nroko top:", first["roko"].most_common(40))
print("\nbrave top:", first["brave"].most_common(20))
