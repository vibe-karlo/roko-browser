#!/usr/bin/env python3
"""Prints what a whole iPhone has received and sent since it started, from a short xctrace
Activity Monitor recording. A recording holds only about a second of samples, so run_sites.sh
takes one before and one after a page and subtracts."""
import subprocess, sys
import xml.etree.ElementTree as ET
query = '/trace-toc/run[@number="1"]/data/table[@schema="sysmon-system"]'
xml = subprocess.run(["xcrun", "xctrace", "export", "--input", sys.argv[1], "--xpath", query], capture_output=True, text=True).stdout
root = ET.fromstring(xml)
columns = [c.findtext("mnemonic") for c in root.iter("col")]
seen, rows = {}, []
for row in root.iter("row"):
    values = []
    for cell in row:
        if "id" in cell.attrib:
            seen[cell.attrib["id"]] = cell.text
        values.append(seen.get(cell.attrib.get("ref"), cell.text))
    rows.append(dict(zip(columns, values)))
print(rows[0]["net-bytes-in"], rows[0]["net-bytes-out"])
