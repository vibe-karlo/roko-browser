#!/usr/bin/env python3
"""Bundles an icon for every site in PopularSites.swift, so address
suggestions show the real mark before you have ever visited the site, with no
network request while typing. Run again after editing the list.

    python3 -I Scripts/fetch_site_icons.py

Icons come from Google's favicon service at 128 px and land in the asset
catalog as site/<host>, which FaviconStore falls back to."""

import json
import pathlib
import re
import shutil
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Browser/Command/PopularSites.swift"
OUT = ROOT / "Browser/Resources/Assets.xcassets/site"


def hosts():
    found = re.findall(r'\("([a-z0-9.\-/]+)", "', SOURCE.read_text())
    # "index.hr/oglasi" uses index.hr's icon.
    return sorted({h.split("/")[0] for h in found})


def fetch(host):
    # The largest size Google has; it answers 404 for a size it lacks.
    for size in (128, 64, 32):
        url = f"https://www.google.com/s2/favicons?domain={host}&sz={size}"
        try:
            with urllib.request.urlopen(url, timeout=15) as response:
                data = response.read()
        except urllib.error.HTTPError:
            continue  # 404 comes with Google's generic globe: not this site's mark
        if data.startswith(b"\x89PNG"):
            return data
    return None


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    (OUT / "Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}}, indent=2))
    missing = []
    for host in hosts():
        data = fetch(host)
        if not data:
            missing.append(host)
            continue
        folder = OUT / f"{host}.imageset"
        folder.mkdir()
        (folder / "icon.png").write_bytes(data)
        (folder / "Contents.json").write_text(json.dumps(
            {"images": [{"filename": "icon.png", "idiom": "universal"}],
             "info": {"author": "xcode", "version": 1}}, indent=2))
    print(f"{len(hosts()) - len(missing)} icons; none for: {', '.join(missing) or 'none'}")


if __name__ == "__main__":
    main()
