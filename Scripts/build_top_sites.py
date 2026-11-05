#!/usr/bin/env python3
"""Builds the sites suggested in the bar: each country's most visited, and the
world's, from the Chrome UX Report (Google, CC BY 4.0) as cached by
github.com/zakird/crux-top-lists. Run again to refresh (a new month appears on
the second Tuesday):

    python3 -I Scripts/build_top_sites.py 202609

One file, Browser/Resources/TopSites/top-sites.bin: a first line of
"code:offset:length" for every country, then each country's hosts, one per
line, most visited first, compressed on their own (raw deflate) so a phone only
ever inflates its own country and the world's ("zz").

Chrome only says a site is in a country's top 1,000, not where. The order inside
comes from the country's own domain ending, then how big the site is worldwide
and in how many countries it's in the top 1,000.

The lists are raw pageloads, so they hold adult, gambling and pirate sites, and
hosts nobody would type (sign-in pages, redirectors). Those go here, at build
time: the filter lists are never shipped. Every host left is then put to
Cloudflare's family resolver (1.1.1.3), which answers 0.0.0.0 for adult sites
and malware, and no address for one that's gone; answers are cached for 30 days
in Scripts/.cache. Sites PopularSites.swift already names are left out too,
since they come with a proper name and an icon."""

import collections
import concurrent.futures
import gzip
import json
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / "Scripts/.cache"
CRUX = CACHE / "crux"
FILTERS = CACHE / "filters"
OUT = ROOT / "Browser/Resources/TopSites/top-sites.bin"
BASE = "https://raw.githubusercontent.com/zakird/crux-top-lists/main/data"

# How many hosts a country keeps, and how many of those may be international.
COUNTRY = 150
COUNTRY_INTERNATIONAL = 40
WORLD = 160
# A site in this many countries' top 1,000 or fewer counts as local to them.
LOCAL_BREADTH = 3
SUBDOMAINS_PER_DOMAIN = 2

FILTER_LISTS = {
    "blp-porn.txt": "https://blocklistproject.github.io/Lists/alt-version/porn-nl.txt",
    "blp-gambling.txt": "https://blocklistproject.github.io/Lists/alt-version/gambling-nl.txt",
    "blp-piracy.txt": "https://blocklistproject.github.io/Lists/alt-version/piracy-nl.txt",
    "blp-scam.txt": "https://blocklistproject.github.io/Lists/alt-version/scam-nl.txt",
    "blp-phishing.txt": "https://blocklistproject.github.io/Lists/alt-version/phishing-nl.txt",
    "blp-malware.txt": "https://blocklistproject.github.io/Lists/alt-version/malware-nl.txt",
    "stevenblack.txt": "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/gambling-porn-only/hosts",
}

# What the filter lists miss, by name. Whole words where a short one would catch
# innocent sites ("essex", "alphabet", "camera").
BAD_ANYWHERE = re.compile(
    r"porn|xxx|xvideo|xnxx|xhamster|redtube|hentai|nude|nudist|naked|escort|erotic|erotik|"
    r"seks|sexy|sexo|fetish|milf|onlyfans|fansly|chaturbate|stripchat|bongacams|livejasmin|"
    r"camsoda|myfreecams|jerk|fapello|fapp|nsfw|boobs|tits|lesbian|shemale|hqporner|simpcity|"
    r"spankbang|rule34|nhentai|javhd|jav[0-9]|adult|dating|hookup|ljubavni|"
    r"casino|kasino|kazino|poker|slots|sportsbet|betting|bookmaker|1xbet|betano|bet365|"
    r"parimatch|pinnacle|tipico|melbet|mostbet|stake\.|pragmaticplay|gambl|lotto|lutrij|"
    r"torrent|piratebay|1337x|yts\.|rarbg|nyaa|fmovies|123movies|gomovies|putlocker|"
    r"serije|filmovi|hdfilm|dizi|repelis|pelisplus|animekimi|mangakakalot|"
    r"loan|payday|crack|keygen|apk|lookmovie|scans|manga|manhwa|anime|toon|stream|mp3|"
    r"ytmp|snaptik|ssstik|savefrom|y2mate|fdown|download|film|movie|hdhub|isaidub|tamildhool|"
    r"togel|judi|gacor|jackpot|loteria|lottery|keirin|boatrace|imgsrc|xhlink|libertin|bhabhi|"
    r"satta|matka|xoso|xskt|turf|sikis|porno|sesso|putas|rencontre|kamasutra|amateur|massage|(?<!es)(?<!mid)(?<!dle)sex"
)
# bet9ja, betway, betika, not "better", "bethesda", "beta".
BAD_BET = re.compile(r"(^|[.\-])bet(?!ter|h|a|ty|el|sy|on)[a-z0-9]*|[a-z]bets?(\.|-)")
BAD_WORD = re.compile(r"(^|[.\-])(sex|bet|bets|cam|cams|tube|fuck|pussy|anal|gay|vip|win|play|game)([.\-]|$)")
# Hosts that are a step on the way to somewhere, not a place to go.
PLUMBING = {
    "account", "accounts", "admin", "adsmanager", "agiris", "api", "app-api", "auth", "autodiscover", "billing", "cas", "cdn", "checkout",
    "click", "clk", "connect", "consent", "cp", "dashboard", "email", "esia", "faq", "gateway", "giris", "go", "help", "id", "identity",
    "idp", "img", "images", "link", "links", "lnk", "log-in", "login", "logon", "mailer", "media", "myaccount", "myactivity", "oauth",
    "pay", "payment", "payments", "prijava", "r", "redirect", "redirector", "s", "secure", "seller", "sellercentral", "signin", "sso",
    "static", "support", "t", "track", "tracking", "url", "vendedores", "verify",
}
PLUMBING_START = re.compile(r"^(redirect|login|auth|sso|track|intralot|s[0-9]+$|ww[0-9]+$|[a-z]{1,2}[0-9]+$)")
# Web versions whose address starts with the same word: "m.facebook.com" is facebook.com.
SAME_SITE = {"www", "www1", "www2", "www3", "m", "mobile", "amp", "touch", "wap", "web", "new", "beta"}
# Endings mostly bought for sites that keep moving: pirate streams, spam. A real
# site on one of these is rare enough to lose.
THROWAWAY = {
    "biz", "buzz", "cc", "cfd", "cf", "click", "club", "cyou", "fun", "ga", "gq", "icu", "la", "lat", "live", "lol",
    "ml", "monster", "mom", "one", "online", "pics", "pw", "quest", "rest", "sbs", "shop", "site", "store", "su",
    "tk", "to", "top", "vip", "win", "ws", "xyz",
}
# Two-letter endings that say nothing about a country.
UNTIED = {"ai", "co", "eu", "fm", "gg", "id", "io", "ly", "me", "tv", "us"}
# Countries whose domains don't end in their code.
ENDINGS = {"gb": "uk"}
# A foreign shop people do cross a border for.
CROSSES_BORDERS = re.compile(r"^(amazon|ebay)\.")
# Read in the lists and left out by hand: link shorteners and gibberish.
NOT_DESTINATIONS = {"bit.ly", "luugy.com", "mesibaza.com", "keops-ingenierie.fr", "entiredust.in"}
# Sites that just send you on to the .com, or whose country versions are the
# same search box: google.hr is google.com to anyone typing it.
SAME_EVERYWHERE = re.compile(r"^(www\.)?(google|bing|yahoo|youtube|wikipedia|facebook|instagram)\.[a-z.]+$")


def fetch(url, path):
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    print(f"  fetching {url}")
    with urllib.request.urlopen(url, timeout=300) as response:
        path.write_bytes(response.read())


def host_of(origin):
    return re.sub(r"^https?://", "", origin).split(":")[0].lower()


def parent_of(host):
    """The domain under a host: "bbc.co.uk" for "news.bbc.co.uk"."""
    labels = host.split(".")
    keep = 3 if len(labels) >= 3 and len(labels[-2]) <= 3 and len(labels[-1]) == 2 else 2
    return ".".join(labels[-keep:])


def tidy(host):
    """The address someone would type for a host, or None if nobody would."""
    if host.startswith("xn--") or ".xn--" in host or re.fullmatch(r"[0-9.]+", host):
        return None
    while host.count(".") >= 2 and host.split(".")[0] in SAME_SITE:
        host = host.split(".", 1)[1]
    # "hr.wikipedia.org", "de-de.example.com": the site, not its language.
    first, _, rest = host.partition(".")
    if host != parent_of(host) and re.fullmatch(r"[a-z]{2}(-[a-z]{2})?", first):
        host = rest
    first = host.split(".")[0]
    if host != parent_of(host) and (first in PLUMBING or PLUMBING_START.match(first)):
        return None
    if SAME_EVERYWHERE.match(host) or len(host) > 40:
        return None
    # "izy0.com", "7hyy.com", "6543.example.com": made up, or a game's server.
    name = parent_of(host).split(".")[0]
    if any(c.isdigit() for c in name) and len(name) <= 6 or re.search(r"[0-9]{3}", first):
        return None
    if host.rsplit(".", 1)[-1] in THROWAWAY:
        return None
    return host


def is_foreign(host, code):
    """A site on another country's ending: Germany's news isn't Croatia's."""
    ending = host.rsplit(".", 1)[-1]
    return len(ending) == 2 and ending != ENDINGS.get(code, code) and ending not in UNTIED and not CROSSES_BORDERS.match(host)


def is_blocked(host, listed):
    if BAD_ANYWHERE.search(host) or BAD_WORD.search(host) or BAD_BET.search(host):
        return True
    # The host or any domain above it, but never a bare ending like "co.uk".
    labels = host.split(".")
    return any(".".join(labels[i:]) in listed for i in range(len(labels) - 1))


def read_listed():
    listed = set()
    for name, url in FILTER_LISTS.items():
        fetch(url, FILTERS / name)
        for line in (FILTERS / name).read_text(errors="ignore").splitlines():
            line = line.split("#")[0].strip().lower()
            if line:
                listed.add(line.split()[-1])
    # roko's own blocker: no suggesting what it would stop.
    for name in ("ads-hosts.txt", "privacy-hosts.txt"):
        listed.update((ROOT / "Browser/Resources/Blocklists" / name).read_text().split())
    return listed


def resolves(host):
    """False if the family resolver blocks it or it doesn't exist; None if it didn't answer."""
    query = urllib.parse.urlencode({"name": host, "type": "A"})
    request = urllib.request.Request(f"https://family.cloudflare-dns.com/dns-query?{query}",
                                     headers={"accept": "application/dns-json", "User-Agent": "roko-build-top-sites/1.0"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                answer = json.load(response)
            if answer.get("Status") == 2:  # the resolver's own failure, not an answer
                continue
            addresses = [a["data"] for a in answer.get("Answer", []) if a.get("type") == 1]
            cnames = [a for a in answer.get("Answer", []) if a.get("type") == 5]
            return (bool(addresses) or bool(cnames)) and "0.0.0.0" not in addresses
        except Exception:
            time.sleep(1 + attempt)
    return None


def safe_hosts(hosts):
    """Which of these the family resolver lets through, cached."""
    path = CACHE / "top-sites-dns.json"
    cache = json.loads(path.read_text()) if path.exists() else {}
    now = time.time()
    stale = sorted(h for h in hosts if h not in cache or now - cache[h][1] > 30 * 86400)
    if stale:
        print(f"dns: asking about {len(stale):,} hosts")
        with concurrent.futures.ThreadPoolExecutor(48) as pool:
            for host, answer in zip(stale, pool.map(resolves, stale)):
                if answer is not None:
                    cache[host] = [answer, now]
        path.write_text(json.dumps(cache))
    unanswered = sum(h not in cache for h in hosts)
    if unanswered:
        print(f"dns: {unanswered} hosts got no answer and are left out; run again to ask them")
    return {h for h in hosts if h in cache and cache[h][0]}


def curated():
    """Hosts PopularSites.swift names, and the domains they stand for."""
    source = (ROOT / "Browser/Command/PopularSites.swift").read_text()
    return {h.split("/")[0] for h in re.findall(r'\("([a-z0-9.\-/]+)", "', source)}


def main():
    month = sys.argv[1] if len(sys.argv) > 1 else "202609"
    names = [line.strip() for line in (CRUX / "countries.txt").read_text().splitlines() if line.strip()]

    world_bucket = {}
    fetch(f"{BASE}/global/{month}.csv.gz", CRUX / f"global-{month}.csv.gz")
    with gzip.open(CRUX / f"global-{month}.csv.gz", "rt") as lines:
        next(lines)
        for line in lines:
            origin, _, rank = line.strip().rpartition(",")
            host = tidy(host_of(origin))
            if host:
                world_bucket[host] = min(world_bucket.get(host, 10**7), int(rank))

    listed = read_listed()
    named = curated()
    tops = {}
    breadth = collections.Counter()
    seen = dropped = 0
    for code in names:
        path = CRUX / "country" / f"{code}-{month}.csv"
        if not path.exists():
            # Only the top of each file: they're sorted by rank, and 800 KB each.
            with urllib.request.urlopen(f"{BASE}/country/{code}/{month}.csv.gz", timeout=300) as response:
                text = gzip.decompress(response.read()).decode()
            path.write_text("\n".join(text.splitlines()[:1001]))
        hosts = set()
        for line in path.read_text().splitlines()[1:]:
            origin, _, rank = line.rpartition(",")
            if int(rank) > 1000:
                continue
            seen += 1
            host = tidy(host_of(origin))
            if host and not is_blocked(host, listed):
                hosts.add(host)
            else:
                dropped += 1
        tops[code] = hosts

    allowed = safe_hosts(set().union(*tops.values()) - named)
    print(f"dns: {len(set().union(*tops.values()) - named - allowed):,} blocked or gone, {len(allowed):,} left")
    # Kept for ranking whatever the resolver said about them: named ones aren't asked.
    for code in tops:
        tops[code] &= allowed | named
        breadth.update(tops[code])

    def order(code, host):
        ours = code != "zz" and host.endswith("." + ENDINGS.get(code, code))
        return (not ours, world_bucket.get(host, 10**7), -breadth[host], len(host), host)

    def thin(hosts):
        """A few subdomains per domain: net.hr has dozens in Croatia's top 1,000."""
        count = collections.Counter()
        kept = []
        for host in hosts:
            parent = parent_of(host)
            if host != parent:
                count[parent] += 1
                if count[parent] > SUBDOMAINS_PER_DOMAIN:
                    continue
            kept.append(host)
        return kept

    slices = {}
    for code, hosts in tops.items():
        here = {host for host in hosts - named - NOT_DESTINATIONS if not is_foreign(host, code)}
        ranked = thin(sorted(here, key=lambda host: order(code, host)))
        local = [h for h in ranked if h.endswith("." + ENDINGS.get(code, code)) or breadth[h] <= LOCAL_BREADTH]
        wide = [h for h in ranked if h not in set(local)]
        room = COUNTRY - min(len(wide), COUNTRY_INTERNATIONAL)
        chosen = set(local[:room]) | set(wide[:COUNTRY - min(len(local), room)])
        slices[code] = [h for h in ranked if h in chosen]

    # The world's: in the most countries' top 1,000, biggest first, and tied to
    # no one country: lemonde.fr is big, but not for someone in Ohio.
    world = [h for h in breadth if world_bucket.get(h, 10**7) <= 1000 and h not in named | NOT_DESTINATIONS
             and (len(h.rsplit(".", 1)[-1]) > 2 or h.rsplit(".", 1)[-1] in UNTIED)]
    world.sort(key=lambda host: (-breadth[host], order("zz", host)))
    slices["zz"] = thin(world)[:WORLD]

    blobs = {code: zlib.compressobj(9, zlib.DEFLATED, -15) for code in slices}
    body = bytearray()
    index = []
    for code, hosts in slices.items():
        compressor = blobs[code]
        blob = compressor.compress("\n".join(hosts).encode()) + compressor.flush()
        index.append(f"{code}:{len(body)}:{len(blob)}")
        body += blob

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(" ".join(index).encode() + b"\n" + bytes(body))
    total = sum(len(hosts) for hosts in slices.values())
    print(f"{len(slices)} lists, {total:,} hosts; {dropped:,} of {seen:,} dropped; {OUT.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
