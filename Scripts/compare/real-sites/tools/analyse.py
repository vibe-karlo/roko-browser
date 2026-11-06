#!/usr/bin/env python3
"""Reads one or more pulled folders. For each run, from the recorded frames:
 start: first frame that differs from the still home screen, so the link's own delay isn't counted
 v85/v95: when the screen last came within 15%/5% of how the run ended, measured from start
 si: Speed Index in seconds, the area above that curve (lower means seen sooner)
 mb: megabytes received in the window, from the phone's Wi-Fi and cellular counters
Prints one JSON line per run. The top and bottom of the screen are left out: clock, island, bars."""
import json, pathlib, struct, sys
import numpy as np
W, H, HEAD = 100, 218, 40
top, bottom = int(H * .13), int(H * .86)
for folder in map(pathlib.Path, sys.argv[1:]):
    log = {}
    for line in open(folder / "log.jsonl"):
        r = json.loads(line)
        if "b" in r: log[r["id"]] = r
    for rid, r in log.items():
        raw = (folder / (rid + ".frames")).read_bytes()
        n = len(raw) // (HEAD + W * H)
        if n < 8: print(json.dumps({"id": rid, "bad": "few frames", "n": n})); continue
        times, inb, frames = [], [], []
        for i in range(n):
            o = i * (HEAD + W * H)
            t, wi, wo, ci, co = struct.unpack("5d", raw[o:o + HEAD])
            times.append(t); inb.append(wi + ci)
            frames.append(np.frombuffer(raw, np.uint8, W * H, o + HEAD).reshape(H, W)[top:bottom].astype(np.int16))
        times = np.array(times); first, final = frames[0], frames[-1]
        moved = [i for i in range(n) if np.abs(frames[i] - first).mean() > 1.5]
        if not moved: print(json.dumps({"id": rid, "bad": "screen never changed"})); continue
        s = moved[0]; d0 = max(np.abs(first - final).mean(), 1)
        done = np.array([1 - np.abs(f - final).mean() / d0 for f in frames]).clip(0, 1)
        def last_below(x):
            below = [i for i in range(s, n) if done[i] < x]
            i = (below[-1] + 1) if below else s
            return float(times[min(i, n - 1)] - times[s])
        # Cells of the screen that already look as they end up: a slideshow or a video moves only
        # its own cells, so it can't hold this back the way it holds back v85 and v95.
        def cells(f):
            return f[: f.shape[0] // 22 * 22, : f.shape[1] // 10 * 10].reshape(22, f.shape[0] // 22, 10, f.shape[1] // 10).mean(axis=(1, 3))
        last = cells(final)
        match = np.array([(np.abs(cells(f) - last) < 10).mean() for f in frames])
        begin = float(match[0])
        # The same, counting only the parts of the screen that end up holding something: a blank
        # white page already matches the white around a page's text, and that isn't a page yet.
        def detail(f):
            return f[: f.shape[0] // 22 * 22, : f.shape[1] // 10 * 10].reshape(22, f.shape[0] // 22, 10, f.shape[1] // 10).std(axis=(1, 3))
        worth = detail(final) > 12
        drawn = np.array([((np.abs(cells(f) - last) < 12) & (detail(f) > 6) & worth).sum() / max(worth.sum(), 1) for f in frames])
        def content(x):
            for i in range(s, n):
                if drawn[i] >= x: return float(times[i] - times[s])
            return float(times[n - 1] - times[s])
        def first_above(x):
            for i in range(s, n):
                if match[i] >= x: return float(times[i] - times[s])
            return float(times[n - 1] - times[s])
        si = float(sum((1 - done[i]) * (times[i + 1] - times[i]) for i in range(s, n - 1)))
        delta = np.diff(np.array(inb)); delta[delta < 0] = 0
        print(json.dumps({"id": rid, "b": r["b"], "site": (rid.split(".") + ["", ""])[1], "pass": folder.name, "n": n, "fps": round(r["fps"], 2), "startAt": round(float(times[s]), 2), "v85": round(last_below(.85), 2), "v95": round(last_below(.95), 2), "si": round(si, 2), "t50": round(first_above(.5), 2), "c50": round(content(.5), 2), "c80": round(content(.8), 2), "t70": round(first_above(.7), 2), "mb": round(float(delta.sum()) / 1e6, 2), "mbOut": round((r["outWifi"] + r["outCell"]) / 1e6, 2), "thermal": r["thermal"], "state": r["state"], "at": r["at"]}))
