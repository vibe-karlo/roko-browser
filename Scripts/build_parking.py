#!/usr/bin/env python3
"""Builds roko's parking zone data from OpenStreetMap (© OpenStreetMap contributors, ODbL).

Each supported city's paid parking areas, with the zone each belongs to, as a
small JSON file in Browser/Resources/Parking. Run again to refresh:

    python3 Scripts/build_parking.py

Only paid areas in zones roko knows (see ParkingCity in Browser/Parking) are
kept; a zone not yet charged (Osijek's II until November 2026) is left out.
"""
import datetime
import json
import os
import sys
import time
import urllib.parse
import urllib.request

CITIES = {
    # Bounding box south, west, north, east; the zones roko supports there.
    "osijek": {"bbox": (45.53, 18.62, 45.58, 18.75), "zones": {"0", "1"}},
}

OVERPASS = "https://overpass-api.de/api/interpreter"
OUT = os.path.join(os.path.dirname(__file__), "..", "Browser", "Resources", "Parking")


def fetch(bbox):
    south, west, north, east = bbox
    query = f'[out:json][timeout:120];way["amenity"="parking"]["parking:zone"]({south},{west},{north},{east});out tags geom;'
    data = urllib.parse.urlencode({"data": query}).encode()
    for attempt in range(6):
        request = urllib.request.Request(OVERPASS, data=data, headers={"User-Agent": "roko-build-parking/1.0"})
        try:
            with urllib.request.urlopen(request, timeout=150) as response:
                return json.load(response)["elements"]
        except Exception as error:  # Overpass rate-limits; wait and try again.
            print(f"  overpass busy ({error}), retrying", file=sys.stderr)
            time.sleep(30 * (attempt + 1))
    sys.exit("Overpass didn't answer")


def main():
    os.makedirs(OUT, exist_ok=True)
    for city, spec in CITIES.items():
        areas = []
        for way in fetch(spec["bbox"]):
            tags = way.get("tags", {})
            zone = tags.get("parking:zone")
            if zone not in spec["zones"] or tags.get("fee") == "no":
                continue
            points = [[round(p["lat"], 6), round(p["lon"], 6)] for p in way.get("geometry", [])]
            if len(points) >= 3:
                areas.append({"z": zone, "p": points})
        payload = {
            "city": city,
            "source": "© OpenStreetMap contributors, ODbL",
            "generated": datetime.date.today().isoformat(),
            "areas": areas,
        }
        path = os.path.join(OUT, f"{city}.json")
        with open(path, "w") as file:
            json.dump(payload, file, separators=(",", ":"))
        counts = {z: sum(1 for a in areas if a["z"] == z) for z in sorted(spec["zones"])}
        print(f"{city}: {len(areas)} areas {counts}, {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main()
