#!/usr/bin/env python3
"""Compares browsers on one iPhone or simulator, the same way for each.

    Scripts/compare/server.py hosts.json [port]

hosts.json is d3ward's public list (toolz, src/data/adblock_data.json), so roko
isn't choosing its own exam. /run?b=<browser>&r=<run> is a page that reports:
 - loaded: when its load event fired. The driver notes the time it asked the
   browser to open the link, so the gap is link to page, launch included.
 - score: which hosts on the list it could not reach.
A host that a browser without a blocker can't reach proves nothing, so report.py
scores only hosts Safari reached. Results go to results.jsonl next to this file.
"""
import json, sys, time, pathlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

here = pathlib.Path(__file__).parent
hosts = []
for group, sites in json.load(open(sys.argv[1])).items():
    for site, entries in sites.items():
        for kind, names in (entries.items() if isinstance(entries, dict) else [("", entries)]):
            hosts += [(group, site, name) for name in (names if isinstance(names, list) else [names])]
page = (here / "page.html").read_text().replace("__HOSTS__", json.dumps(hosts))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_GET(self):
        url = urlparse(self.path)
        body, kind = page.encode(), "text/html"
        if url.path != "/run":
            body, kind = b"", "text/plain"
        self.send_response(200)
        self.send_header("content-type", kind)
        self.send_header("cache-control", "no-store")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers["content-length"])))
        data["at"] = time.time()
        with open(here / "results.jsonl", "a") as out:
            out.write(json.dumps(data) + "\n")
        self.send_response(204)
        self.end_headers()


ThreadingHTTPServer(("0.0.0.0", int(sys.argv[2]) if len(sys.argv) > 2 else 8765), Handler).serve_forever()
