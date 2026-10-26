#!/usr/bin/env python3
"""Builds Browser/Resources/Shopping/products.txt, the shop range Shopping
suggests from as you type, from a price list as Croatian shops publish them
(tab-separated, the product name in the first column).

    Scripts/build_shopping_catalogue.py prices.csv

Names with till abbreviations ("KLC.", "Pileća pr.") are left out; sizes and
what follows them go ("PIK Kobasica Roštiljska 460g" is "PIK Kobasica Roštiljska").
everyday.txt, the everyday things in Croatian and English, is kept by hand."""
import re
import sys
from pathlib import Path

rows = Path(sys.argv[1]).read_text(encoding="utf-8-sig").splitlines()[1:]
names = set()
for row in rows:
    name = row.split("\t")[0].strip()
    if re.search(r"[._,%/&+´`]|\b(KLC|KC|K-Classic|KFav|KBio|NMNP)\b", name):
        continue
    name = re.sub(r"\s*\d+([,.]\d+)?\s*(x\s*\d+\s*)?(g|kg|ml|l|L|cl|dl|kom|KOM|m)\b.*$", "", name)
    name = re.sub(r"\s+\d+\s*$", "", name).strip()
    name = re.sub(r"\s{2,}", " ", name)
    if 4 <= len(name) <= 40 and not re.search(r"\d{2,}", name):
        names.add(name)
out = Path(__file__).resolve().parent.parent / "Browser/Resources/Shopping/products.txt"
out.write_text("\n".join(sorted(names, key=str.lower)) + "\n")
print(f"{len(rows)} products, {len(names)} kept: {out}")
