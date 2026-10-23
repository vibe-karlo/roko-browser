#!/bin/bash
# Builds roko's cookie pop-up scripts from DuckDuckGo's Autoconsent (MPL-2.0):
#   Browser/Resources/Scripts/consent-main.js   for the page, with every rule
#   Browser/Resources/Scripts/consent-frame.js  for frames, with the frame rules only
# Run: Scripts/build_consent.sh   (needs node and npm)
set -euo pipefail
VERSION=16.60.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$ROOT"/Scripts/consent/*.js "$WORK"/
cd "$WORK"
npm init -y >/dev/null
npm install --silent --no-audit --no-fund "@duckduckgo/autoconsent@$VERSION" esbuild@0.25.10 >/dev/null

# The frame rules on their own, so frames don't parse the whole rule set.
node -e '
const all = require("@duckduckgo/autoconsent/rules/compact-rules.json");
const [from, to] = all.index.frameRuleRange;
const r = all.r.slice(from, to);
const s = all.s.slice(0, all.index.frameStringEnd);
const index = { genericRuleRange: [0, 0], frameRuleRange: [0, r.length], specificRuleRange: [r.length, r.length],
                genericStringEnd: 0, frameStringEnd: s.length };
require("fs").writeFileSync("frame-rules.json", JSON.stringify({ v: all.v, s, r, index }));
'

OUT="$ROOT/Browser/Resources/Scripts"
BANNER="// Built by Scripts/build_consent.sh from @duckduckgo/autoconsent $VERSION (MPL-2.0, https://github.com/duckduckgo/autoconsent)."
for entry in main frame; do
  npx esbuild "$entry.js" --bundle --minify --format=iife --target=safari17 \
    --banner:js="$BANNER" --outfile="$OUT/consent-$entry.js" --log-level=warning
done
ls -l "$OUT"/consent-*.js
