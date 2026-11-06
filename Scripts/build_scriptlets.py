#!/usr/bin/env python3
"""Turn uBlock Origin's site scripts ("##+js" rules) into the table roko ships.

A site's own anti-adblock wall is usually beaten by a small change to its page
before it runs: BILD reads a flag, "adBlockWallEnabled":true, and with it false
there is no wall, while its ads stay blocked. Content rule lists can't do that.
uBlock Origin's lists hold such a rule for about ten thousand sites.

Only scripts Browser/Resources/Scripts/site-scripts.js implements are kept, and
rules for a named site or "name.*": a rule for every site would cost every page.
Only the page's own site is looked up, so a site with no rule pays nothing.

The rules are uBlock Origin's (GPL-3.0, https://github.com/uBlockOrigin/uAssets).

Usage:
    python3 -I Scripts/build_scriptlets.py            # download + convert
    python3 -I Scripts/build_scriptlets.py --offline  # reuse Scripts/.cache
"""

import json
import re
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "Scripts" / ".cache" / "ublock"
OUT = ROOT / "Browser" / "Resources" / "Blocklists" / "site-scripts.txt"
BASE = "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/"
FILES = ["filters", "quick-fixes", "unbreak", "privacy"] + [f"filters-{y}" for y in range(2020, 2027)]

# What the conditions in the lists mean for roko: a WebKit browser on a phone,
# with no HTML filtering and not the uBO Lite extension.
TRUE = {"env_safari", "env_mobile", "cap_user_stylesheet"}

# Every spelling of a script, to the name site-scripts.js knows it by.
NAMES = {
    "set": ["set", "set-constant"],
    "aopr": ["aopr", "abort-on-property-read"],
    "aopw": ["aopw", "abort-on-property-write"],
    "acs": ["acs", "acis", "abort-current-script", "abort-current-inline-script"],
    "aost": ["aost", "abort-on-stack-trace"],
    "aeld": ["aeld", "addEventListener-defuser", "aeld.js"],
    "nostif": ["nostif", "no-setTimeout-if", "setTimeout-defuser", "nosiif-timeout"],
    "nosiif": ["nosiif", "no-setInterval-if", "setInterval-defuser"],
    "nano-stb": ["nano-stb", "nano-setTimeout-booster", "adjust-setTimeout"],
    "nano-sib": ["nano-sib", "nano-setInterval-booster", "adjust-setInterval"],
    "no-fetch-if": ["no-fetch-if", "prevent-fetch"],
    "no-xhr-if": ["no-xhr-if", "prevent-xhr"],
    "noeval-if": ["noeval-if", "noeval"],
    "nowoif": ["nowoif", "no-window-open-if", "window.open-defuser"],
    "rmnt": ["rmnt", "remove-node-text"],
    "rpnt": ["rpnt", "replace-node-text", "trusted-rpnt", "trusted-replace-node-text"],
    "ra": ["ra", "remove-attr"],
    "rc": ["rc", "remove-class"],
    "json-prune": ["json-prune"],
    "repl-arg": ["trusted-replace-argument", "trusted-ra"],
    "ssi": ["set-local-storage-item"],
    "scookie": ["set-cookie"],
    "rcookie": ["remove-cookie", "cookie-remover"],
}
CANON = {spelling: name for name, spellings in NAMES.items() for spelling in spellings}
CANON.update({spelling + ".js": name for spelling, name in list(CANON.items())})
CANON.update({"ubo-" + spelling: name for spelling, name in list(CANON.items())})


def read(name, offline):
    path = CACHE / f"{name}.txt"
    if not offline:
        CACHE.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(BASE + f"{name}.txt", timeout=60) as response:
            path.write_bytes(response.read())
    return path.read_text(errors="ignore")


def holds(expression):
    """One side of "!#if": names joined by || and &&, each perhaps negated."""
    def term(token):
        token = token.strip().strip("()")
        return token[1:] not in TRUE if token.startswith("!") else token in TRUE
    return any(all(term(t) for t in part.split("&&")) for part in expression.split("||"))


def live_lines(text):
    stack = []
    for line in text.splitlines():
        if line.startswith("!#if "):
            stack.append(holds(line[5:]))
        elif line.startswith("!#else"):
            if stack:
                stack[-1] = not stack[-1]
        elif line.startswith("!#endif"):
            if stack:
                stack.pop()
        elif all(stack) and line and not line.startswith("!"):
            yield line


def split_args(body):
    """"a, b\\, c, 'd, e'" into its arguments. An argument is quoted only if its closing
    quote ends it: "k":true, "k":false is two arguments, each with its quotes kept."""
    args, i = [], 0
    while i <= len(body):
        while i < len(body) and body[i] == " ":
            i += 1
        if i < len(body) and body[i] in "'\"`":
            quote, j = body[i], i + 1
            while j < len(body):
                if body[j] == quote and body[j - 1] != "\\" and re.match(r"\s*(,|$)", body[j + 1:]):
                    break
                j += 1
            if j < len(body):
                args.append(body[i + 1:j].replace("\\" + quote, quote))
                i = body.find(",", j)
                i = len(body) + 1 if i < 0 else i + 1
                continue
        current = ""
        while i < len(body) and body[i] != ",":
            if body[i] == "\\" and i + 1 < len(body) and body[i + 1] == ",":
                i += 1
            current += body[i]
            i += 1
        args.append(current.strip())
        i += 1
    return args


RULE = re.compile(r"^([^#]*)(#@?#)\+js\((.*)\)$")
HOST = re.compile(r"^[a-z0-9.-]+(\.\*)?$")


def main():
    offline = "--offline" in sys.argv
    rules, exceptions, kept, dropped = defaultdict(list), defaultdict(set), 0, defaultdict(int)
    for name in FILES:
        for line in live_lines(read(name, offline)):
            match = RULE.match(line)
            if not match:
                continue
            hosts, kind, body = match.groups()
            args = split_args(body)
            script = CANON.get(args[0])
            if kind == "#@#":
                for host in hosts.split(","):
                    exceptions[host].add(body)
                continue
            if not script:
                dropped[args[0]] += 1
                continue
            call = [script] + args[1:]
            for host in hosts.split(","):
                if HOST.match(host) and "." in host and host != "*":
                    if all(call != c for c, _ in rules[host]):
                        rules[host].append((call, body))
                        kept += 1

    lines = []
    for host in sorted(rules):
        calls = [call for call, body in rules[host] if body not in exceptions[host] and "" not in exceptions[host]]
        if calls:
            lines.append(host + "\t" + json.dumps(calls, ensure_ascii=False, separators=(",", ":")))
    # Led by a line break, so "\nhost\t" finds any row, the first too.
    OUT.write_text("\n" + "\n".join(lines) + "\n")
    print(f"{len(lines)} sites, {kept} rules, {OUT.stat().st_size / 1024:.0f} KB")
    print("not implemented:", sorted(dropped.items(), key=lambda kv: -kv[1])[:12])


if __name__ == "__main__":
    main()
