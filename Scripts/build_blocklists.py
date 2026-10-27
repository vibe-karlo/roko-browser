#!/usr/bin/env python3
"""Convert Adblock Plus filter lists into WebKit content-blocker JSON.

Runs on the Mac at build time, so no converter ships inside the app.
Unsupported syntax (scriptlets, procedural cosmetics, regex rules, redirect
options and so on) is skipped rather than approximated: a rule that matches
too much breaks pages, a rule that is missing only lets an ad through.

Domains that no longer exist are dropped: EasyList has kept ad servers for
years, and about a fifth of them are gone. A host counts as gone only when
both Cloudflare's and Google's resolvers say it doesn't exist (NXDOMAIN),
asked over HTTPS so a filtering resolver on this Mac can't make a live ad
server look dead. Answers are cached in Scripts/.cache/dns.json for 30 days.

Plain "block this host" rules, nine in ten, ship as a list of hosts
(<name>-hosts.txt) that the app turns into rules when it compiles: a fifth of
the size of the same rules as JSON.

Usage:
    python3 -I Scripts/build_blocklists.py            # download + convert
    python3 -I Scripts/build_blocklists.py --offline  # reuse Scripts/.cache, no DNS
    python3 -I Scripts/build_blocklists.py --offline --dns  # cached lists, fresh DNS
"""

import json
import re
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
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
# Subdomains as "anything up to a slash": WebKit compiles that a tenth smaller
# than "anything without a colon or slash", and matches the same real addresses.
DOMAIN_ANCHOR = "^[^:]+://+([^/]+\\.)?"

# A whole host at the start of a domain-anchored rule, followed by something
# that ends a host: only then is it a full name worth asking DNS about
# ("||ads.example" alone could be the start of a longer one).
ANCHORED_HOST = re.compile(r"((?:[a-z0-9-]+\\\.)+[a-z]{2,63})(?=\[/:\?&=\]|\$|/|:)")

# How long a DNS answer is trusted before it's asked again.
DNS_DAYS = 30


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


def hiding_text(cosmetic: dict) -> str:
    """The hiding index as lines, which the app reads in half the time JSON
    takes: "key<TAB>selector" lines, then a \\x01 line before the selectors
    for every page, another before "site<TAB>selector" lines, and another
    before the sites left alone. Selectors never hold a tab or a line break."""
    lines = [f"{key}\t{selector}" for key, selectors in cosmetic["keyed"].items() for selector in selectors]
    lines += ["\x01always", *cosmetic["always"], "\x01scoped"]
    lines += [f"{site}\t{selector}" for site, selectors in cosmetic["scoped"].items() for selector in selectors]
    lines += ["\x01untouched", *cosmetic["untouched"]]
    assert not any("\n" in line or line.count("\t") > 1 for line in lines)
    return "\n".join(lines) + "\n"


def anchored_host(rule: dict) -> str | None:
    url_filter = rule["trigger"].get("url-filter", "")
    if not url_filter.startswith(DOMAIN_ANCHOR):
        return None
    match = ANCHORED_HOST.match(url_filter, len(DOMAIN_ANCHOR))
    return match.group(1).replace("\\.", ".") if match else None


def is_plain_host(rule: dict, host: str) -> bool:
    """Blocks a host and nothing else: no types, no domains, no party."""
    return (rule["action"]["type"] == "block" and list(rule["trigger"]) == ["url-filter"]
            and rule["trigger"]["url-filter"] == DOMAIN_ANCHOR + host.replace(".", "\\.") + SEPARATOR)


def nxdomain(host: str, server: str) -> bool | None:
    base = {"cloudflare": "https://cloudflare-dns.com/dns-query?", "google": "https://dns.google/resolve?"}[server]
    request = urllib.request.Request(base + urllib.parse.urlencode({"name": host, "type": "A"}),
                                     headers={"accept": "application/dns-json", "User-Agent": "BrowserBlocklistBuilder/1.0"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return json.load(response).get("Status") == 3
        except Exception:
            time.sleep(1 + attempt)
    return None  # no answer: kept, as if alive


def dead_hosts(hosts: set[str], offline: bool) -> set[str]:
    """Hosts both resolvers say don't exist, from the cache and fresh lookups."""
    path = CACHE / "dns.json"
    cache: dict[str, list] = json.loads(path.read_text()) if path.exists() else {}
    now = time.time()
    stale = sorted(h for h in hosts if h not in cache or now - cache[h][1] > DNS_DAYS * 86400)
    if stale and not (offline and "--dns" not in sys.argv):
        print(f"dns: asking about {len(stale)} hosts")
        with ThreadPoolExecutor(64) as pool:
            first = list(pool.map(lambda h: nxdomain(h, "cloudflare"), stale))
        candidates = [h for h, gone in zip(stale, first) if gone]
        with ThreadPoolExecutor(64) as pool:
            second = dict(zip(candidates, pool.map(lambda h: nxdomain(h, "google"), candidates)))
        for host, gone in zip(stale, first):
            if gone is None:
                continue  # no answer: ask again next time
            cache[host] = [bool(gone and second.get(host)), now]
        path.write_text(json.dumps(cache, separators=(",", ":")))
    return {h for h in hosts if cache.get(h, [False])[0]}


def main() -> int:
    offline = "--offline" in sys.argv
    OUT.mkdir(parents=True, exist_ok=True)
    sources: dict[str, list[str]] = {}
    converted: dict[str, tuple[list[dict], dict, dict]] = {}
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
        converted[name] = convert(lines)

    # Every host named in full, by a rule or as a site hiding rules are for.
    hosts = set()
    for rules, cosmetic, _ in converted.values():
        hosts |= {h for h in map(anchored_host, rules) if h}
        hosts |= set(cosmetic["scoped"])
    dead = dead_hosts(hosts, offline)
    print(f"dns: {len(dead)} of {len(hosts)} hosts no longer exist")

    for name, (rules, cosmetic, stats) in converted.items():
        kept, plain = [], []
        for rule in rules:
            host = anchored_host(rule)
            if host in dead:
                continue
            if host and is_plain_host(rule, host):
                plain.append(host)
            else:
                kept.append(rule)
        cosmetic["scoped"] = {site: selectors for site, selectors in cosmetic["scoped"].items() if site not in dead}
        if len(kept) + len(plain) > MAX_RULES:
            print(f"  {len(kept) + len(plain)} rules is over WebKit's {MAX_RULES} limit", file=sys.stderr)
            return 1
        (OUT / f"{name}.json").write_text(json.dumps(kept, separators=(",", ":")))
        (OUT / f"{name}-hosts.txt").write_text("\n".join(sorted(set(plain))) + "\n")
        (OUT / f"{name}-hide.txt").write_text(hiding_text(cosmetic))
        (OUT / f"{name}-hide.json").unlink(missing_ok=True)  # the format before
        print(
            f"{name}: {stats['input']} filters -> {len(kept) + len(plain)} network rules "
            f"({len(plain)} plain hosts, {stats['output'] - len(kept) - len(plain)} for dead hosts dropped), "
            f"{stats['hide']} hiding rules ({len(cosmetic['keyed'])} keys, {len(cosmetic['always'])} always, "
            f"{len(cosmetic['scoped'])} sites), {stats['skipped']} skipped"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
