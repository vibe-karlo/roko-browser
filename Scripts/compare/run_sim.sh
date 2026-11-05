#!/bin/zsh
# Link to page in the simulator: each browser quit, then asked to open the link.
# Usage: Scripts/compare/run_sim.sh <device> <runs>
here=${0:a:h}; device=$1; runs=${2:-5}; base=http://127.0.0.1:8765/run
note() { curl -s -X POST localhost:8765/report -d "{\"b\":\"$1\",\"r\":\"$2\",\"kind\":\"start\"}" >/dev/null; }
for r in $(seq 1 $runs); do
  xcrun simctl terminate $device com.apple.mobilesafari 2>/dev/null; xcrun simctl terminate $device com.growthstudio.roko 2>/dev/null; sleep 2
  note safari $r; xcrun simctl openurl $device "$base?b=safari&r=$r"; sleep 6
  xcrun simctl terminate $device com.apple.mobilesafari 2>/dev/null; sleep 2
  note roko $r; xcrun simctl openurl $device "roko://open?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$base?b=roko&r=$r")"; sleep 6
done
