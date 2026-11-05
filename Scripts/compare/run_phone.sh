#!/bin/zsh
# Link to page, and hosts blocked, on a real iPhone: unlocked, on the Mac's Wi-Fi,
# with the server running. Tests whichever of these browsers are installed.
# Usage: Scripts/compare/run_phone.sh <device> <runs> ["brave chrome"]
device=$1; runs=${2:-5}; ip=$(ipconfig getifaddr en0); base=http://$ip:8765/run
apps=(safari com.apple.mobilesafari roko com.growthstudio.roko brave com.brave.ios.browser duckduckgo com.duckduckgo.mobile.ios firefox org.mozilla.ios.Firefox focus org.mozilla.ios.Focus chrome com.google.chrome.ios edge com.microsoft.msedge opera com.opera.OperaTouch vivaldi com.vivaldi.browser ecosia com.ecosia.ecosiaapp arc company.thebrowser.ArcMobile2 lens com.angelakismax.browser)
installed=$(xcrun devicectl device info apps --device $device --include-all-apps 2>/dev/null)
open() { # name bundle url
  if [[ $1 == roko ]]; then
    xcrun devicectl device process launch --device $device --terminate-existing --payload-url "roko://open?url=$(python3 -I -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$3")" $2 >/dev/null 2>&1
  else
    xcrun devicectl device process launch --device $device --terminate-existing --payload-url "$3" $2 >/dev/null 2>&1
  fi
}
only=${3:-}
for name bundle in $apps; do
  [[ -n $only && " $only " != *" $name "* ]] && continue
  [[ $installed == *$bundle* ]] || { echo "$name: not installed"; continue; }
  echo "$name"
  for r in $(seq 1 $runs); do
    curl -s -X POST localhost:8765/report -d "{\"b\":\"$name\",\"r\":\"$r\",\"kind\":\"start\"}" >/dev/null
    open $name $bundle "$base?b=$name&r=$r"; sleep 8
  done
  open $name $bundle "$base?b=$name&r=score&score=1"; sleep 120
done
