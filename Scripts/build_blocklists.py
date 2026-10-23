#!/usr/bin/env python3
"""Convert Adblock Plus filter lists into WebKit content-blocker JSON.

Runs on the Mac at build time, so no converter ships inside the app.
Unsupported syntax (scriptlets, procedural cosmetics, regex rules, redirect
options and so on) is skipped rather than approximated: a rule that matches
too much breaks pages, a rule that is missing only lets an ad through.

Usage:
    python3 -I Scripts/build_blocklists.py            # download + convert
    python3 -I Scripts/build_blocklists.py --offline  # reuse Scripts/.cache
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "Scripts" / ".cache"
OUT = ROOT / "Browser" / "Resources" / "Blocklists"

LISTS = {
    "ads": "https://easylist.to/easylist/easylist.txt",
    "privacy": "https://easylist.to/easylist/easyprivacy.txt",
    "cookies": "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt",
    # Newsletter, subscription and promo overlays, social widgets, nags.
    "popups": "https://easylist.to/easylist/fanboy-annoyance.txt",
}

# The annoyance list repeats cookie filters; dropping those keeps the
# "Cookie banners" and "Pop-ups" switches independent.
DEDUPE_AGAINST = {"popups": "cookies"}

# WebKit refuses to compile a list past this size.
MAX_RULES = 150_000

RESOURCE_TYPES = {
    "script": "script",
    "image": "image",
    "stylesheet": "style-sheet",
    "font": "font",
    "media": "media",
    "xmlhttprequest": "fetch",
    "subdocument": "document",
    "ping": "ping",
    "websocket": "websocket",
    "popup": "popup",
    "other": "other",
    "object": "other",
}

# Options that only adjust matching and are safe to drop.
IGNORED_OPTIONS = {"important", "match-case", "all", "1p", "first-party"}

# Cosmetic selector features WebKit's CSS engine can't take, or that are
# Adblock-only extensions. One bad selector poisons a whole stylesheet.
BAD_SELECTOR = re.compile(
    r":-abp-|:has-text|:contains|:xpath|:upward|:remove|:style|:matches-|"
    r":min-text|:watch-attr|:others|:if|\[-ext-|:nth-ancestor|:matches-path"
)

SEPARATOR = "[/:?&=]"
DOMAIN_ANCHOR = "^[^:]+://+([^:/]+\\.)?"


def fetch(name: str, url: str, offline: bool) -> list[str]:
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f"{name}.txt"
    if not offline:
        print(f"  downloading {url}")
        # The list hosts reject Python's default user agent.
        request = urllib.request.Request(url, headers={"User-Agent": "BrowserBlocklistBuilder/1.0"})
        with urllib.request.urlopen(request, timeout=60) as response:
            path.write_bytes(response.read())
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def pattern_to_regex(pattern: str) -> str | None:
    if pattern.startswith("/") and pattern.endswith("/") and len(pattern) > 2:
        return None  # regex rules are mostly beyond WebKit's regex subset
    if not pattern.isascii():
        return None

    prefix, suffix = "", ""
    if pattern.startswith("||"):
        prefix, pattern = DOMAIN_ANCHOR, pattern[2:]
    elif pattern.startswith("|"):
        prefix, pattern = "^", pattern[1:]
    if pattern.endswith("|"):
        suffix, pattern = "$", pattern[:-1]

    if "|" in pattern:
        return None  # WebKit has no alternation
    pattern = pattern.strip("*") if not prefix else pattern.rstrip("*")
    if len(pattern.replace("*", "").replace("^", "")) < 4:
        return None  # too short to be anything but a false positive

    out = []
    for char in pattern:
        if char == "*":
            out.append(".*")
        elif char == "^":
            out.append(SEPARATOR)
        elif char in ".+?{}()[]\\$":
            out.append("\\" + char)
        else:
            out.append(char)
    return prefix + "".join(out) + suffix


def parse_domains(value: str) -> tuple[list[str], list[str]]:
    include, exclude = [], []
    for domain in value.split("|"):
        domain = domain.strip().lower()
        if not domain or "*" in domain or not domain.isascii():
            continue
        if domain.startswith("~"):
            exclude.append("*" + domain[1:])
        else:
            include.append("*" + domain)
    return include, exclude


def network_rule(line: str) -> dict | None:
    exception = line.startswith("@@")
    if exception:
        line = line[2:]

    pattern, _, options = line.partition("$")
    trigger: dict = {}
    resource_types: list[str] = []
    whole_document = False

    for option in filter(None, options.split(",")):
        name, _, value = option.partition("=")
        name = name.strip().lower()
        if name in IGNORED_OPTIONS:
            continue
        if name in ("third-party", "3p"):
            trigger["load-type"] = ["third-party"]
        elif name in ("~third-party", "~3p"):
            trigger["load-type"] = ["first-party"]
        elif name in RESOURCE_TYPES:
            resource_types.append(RESOURCE_TYPES[name])
        elif name == "document" and exception:
            whole_document = True
        elif name == "domain":
            include, exclude = parse_domains(value)
            if include:
                trigger["if-domain"] = include
            elif exclude:
                trigger["unless-domain"] = exclude
            else:
                return None
        else:
            return None  # redirect, csp, removeparam, negated types, ...

    if exception and whole_document:
        domain = pattern.lstrip("|").rstrip("^|/").lower()
        if not domain or "/" in domain or "*" in domain or not domain.isascii():
            return None
        return {
            "trigger": {"url-filter": ".*", "if-domain": ["*" + domain]},
            "action": {"type": "ignore-previous-rules"},
        }

    regex = pattern_to_regex(pattern)
    if regex is None:
        return None
    trigger = {"url-filter": regex, **trigger}
    if resource_types:
        trigger["resource-type"] = sorted(set(resource_types))
    action = "ignore-previous-rules" if exception else "block"
    return {"trigger": trigger, "action": {"type": action}}


# A class or id token outside :not(), attribute brackets and other functional
# pseudo-classes. Any such token is a necessary condition for the selector to
# match, so a page that lacks it can skip the selector entirely.
KEY_TOKEN = re.compile(r"(?<![\w\\-])([#.])(-?[A-Za-z_][\w-]*)")


def cosmetic_key(selector: str) -> str | None:
    if "\\" in selector:
        return None  # escaped identifiers: rare, just always apply them
    stripped = re.sub(r":not\([^)]*\)", "", selector)
    stripped = re.sub(r"\[[^\]]*\]", "", stripped)
    stripped = re.sub(r":[\w-]+\([^)]*\)", "", stripped)
    matches = KEY_TOKEN.findall(stripped)
    if not matches:
        return None
    sigil, name = matches[-1]  # the subject's token is usually the most specific
    return sigil + name


def convert(lines: list[str]) -> tuple[list[dict], dict, dict]:
    """Returns WebKit network rules, the on-demand hiding index, and stats.

    Hiding rules stay out of WebKit's rule lists on purpose: WebKit applies
    every site-agnostic one to every page as a stylesheet, which measurably
    delays first paint. The app serves them per page instead (CosmeticFilter).
    """
    blocks, exceptions = [], []
    keyed: dict[str, list[str]] = {}
    always: list[str] = []
    scoped: dict[str, list[str]] = {}
    stats = {"input": 0, "skipped": 0, "hide": 0}

    for raw in lines:
        line = raw.strip()
        if not line or line.startswith(("!", "[")):
            continue
        stats["input"] += 1

        if "#@#" in line or "#?#" in line or "#$#" in line or "##+js" in line:
            stats["skipped"] += 1
            continue

        if "##" in line:
            domains, _, selector = line.partition("##")
            if not selector or BAD_SELECTOR.search(selector) or not selector.isascii():
                stats["skipped"] += 1
                continue
            stats["hide"] += 1
            if not domains:
                key = cosmetic_key(selector)
                if key:
                    keyed.setdefault(key, []).append(selector)
                else:
                    always.append(selector)
                continue
            include, _ = parse_domains(domains.replace(",", "|"))
            if not include:
                stats["skipped"] += 1  # "everywhere except" hiding: too rare to model
                continue
            for domain in include:
                scoped.setdefault(domain.lstrip("*"), []).append(selector)
            continue

        rule = network_rule(line)
        if rule is None:
            stats["skipped"] += 1
        elif rule["action"]["type"] == "ignore-previous-rules":
            exceptions.append(rule)
        else:
            blocks.append(rule)

    # Sites whose filter list says "don't touch this site at all".
    untouched = sorted({
        domain.lstrip("*")
        for rule in exceptions
        if rule["trigger"].get("url-filter") == ".*"
        for domain in rule["trigger"].get("if-domain", [])
    })

    # Exceptions only cancel rules that come before them, so they go last.
    rules = blocks + exceptions
    cosmetic = {"keyed": keyed, "always": always, "scoped": scoped, "untouched": untouched}
    stats.update(output=len(rules), block=len(blocks), allow=len(exceptions))
    return rules, cosmetic, stats


def main() -> int:
    offline = "--offline" in sys.argv
    OUT.mkdir(parents=True, exist_ok=True)
    sources: dict[str, list[str]] = {}
    for name, url in LISTS.items():
        print(f"{name}:")
        lines = fetch(name, url, offline)
        extra = ROOT / "Scripts" / "extra" / f"{name}.txt"
        if extra.exists():
            lines += extra.read_text(encoding="utf-8").splitlines()
        if name in DEDUPE_AGAINST:
            shared = {line.strip() for line in sources[DEDUPE_AGAINST[name]]}
            lines = [line for line in lines if line.strip() not in shared]
        sources[name] = lines
        rules, cosmetic, stats = convert(lines)
        if len(rules) > MAX_RULES:
            print(f"  {len(rules)} rules is over WebKit's {MAX_RULES} limit", file=sys.stderr)
            return 1
        (OUT / f"{name}.json").write_text(json.dumps(rules, separators=(",", ":")))
        (OUT / f"{name}-hide.json").write_text(json.dumps(cosmetic, separators=(",", ":")))
        print(
            f"  {stats['input']} filters -> {stats['output']} network rules "
            f"({stats['block']} block, {stats['allow']} allow), {stats['hide']} hiding rules "
            f"({len(cosmetic['keyed'])} keys, {len(cosmetic['always'])} always, "
            f"{len(cosmetic['scoped'])} sites), {stats['skipped']} skipped"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
