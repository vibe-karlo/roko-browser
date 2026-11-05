#!/bin/zsh
# Each browser opens each ad-heavy site cold, through proxy.py, then gets time to load.
# Usage: Scripts/compare/run_sites.sh <device> [seconds per page]
here=${0:a:h}; device=$1; wait=${2:-45}
sites=(dailymail https://www.dailymail.co.uk/home/index.html thesun https://www.thesun.co.uk/ forbes https://www.forbes.com/)
apps=(safari com.apple.mobilesafari roko com.growthstudio.roko brave com.brave.ios.browser duckduckgo com.duckduckgo.mobile.ios firefox org.mozilla.ios.Firefox chrome com.google.chrome.ios edge com.microsoft.msedge arc company.thebrowser.ArcMobile2 lens com.angelakismax.browser)
installed=$(xcrun devicectl device info apps --device $device --include-all-apps 2>/dev/null)
for name bundle in $apps; do
  [[ $installed == *$bundle* ]] || { echo "$name: not installed"; continue; }
  for site url in $sites; do
    echo "$name $site"
    print -r -- "$name/$site" > $here/sites-label.txt
    if [[ $name == roko ]]; then
      target="roko://open?url=$(python3 -I -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$url")"
    else
      target=$url
    fi
    xcrun devicectl device process launch --device $device --terminate-existing --payload-url "$target" $bundle >/dev/null 2>&1
    sleep $wait
  done
done
print -r -- idle > $here/sites-label.txt
