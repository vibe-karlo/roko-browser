#!/bin/zsh
# Data each browser pulls from ad-heavy sites, on a real iPhone that's unlocked and otherwise
# idle. The counters cover the whole phone, not one app, so idle windows give a baseline.
# Writes sites.jsonl. Usage: Scripts/compare/run_sites.sh <device> [seconds] ["safari roko"]
here=${0:a:h}; device=$1; seconds=${2:-40}; only=${3:-}; tmp=$(mktemp -d)
sites=(dailymail https://www.dailymail.co.uk/home/index.html thesun https://www.thesun.co.uk/)
apps=(safari com.apple.mobilesafari roko com.growthstudio.roko brave com.brave.ios.browser duckduckgo com.duckduckgo.mobile.ios firefox org.mozilla.ios.Firefox chrome com.google.chrome.ios edge com.microsoft.msedge arc company.thebrowser.ArcMobile2 lens com.angelakismax.browser)
snapshot() {
  rm -rf $tmp/t.trace
  xcrun xctrace record --device $device --template 'Activity Monitor' --all-processes --time-limit 2s --output $tmp/t.trace >/dev/null 2>&1
  python3 -I $here/trace_bytes.py $tmp/t.trace
}
measure() { # browser site url(optional) bundle(optional)
  local lock=$(xcrun devicectl device info lockState --device $device 2>/dev/null)
  [[ $lock == *"passcodeRequired: false"* ]] || { echo "$1 $2: phone locked, skipped"; print -r -- "{\"b\":\"$1\",\"site\":\"$2\",\"skipped\":\"locked\"}" >> $here/sites.jsonl; return; }
  local before=(${=$(snapshot)})
  if [[ -n ${3:-} ]]; then
    local target=$3
    [[ $1 == roko ]] && target="roko://open?url=$(python3 -I -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$3")"
    xcrun devicectl device process launch --device $device --terminate-existing --payload-url "$target" $4 >/dev/null 2>&1
  fi
  sleep $seconds
  local after=(${=$(snapshot)})
  local down=$(( after[1] - before[1] )) up=$(( after[2] - before[2] ))
  echo "$1 $2 in=$down out=$up"
  print -r -- "{\"b\":\"$1\",\"site\":\"$2\",\"in\":$down,\"out\":$up}" >> $here/sites.jsonl
}
measure idle before
for name bundle in $apps; do
  [[ -n $only && " $only " != *" $name "* ]] && continue
  for site url in $sites; do measure $name $site $url $bundle; done
done
measure idle after
