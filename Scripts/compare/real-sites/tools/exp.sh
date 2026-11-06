#!/bin/zsh
# exp.sh <seconds> <url> [flags]: cold-launch roko on the phone at that page, print what it says.
D=${DEVICE:?set DEVICE to your iPhone id}; secs=$1; url=$2; shift 2
enc=$(python3 -I -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$url")
out=$(mktemp)
xcrun devicectl device process launch --device $D --console --terminate-existing --payload-url "roko://open?url=$enc" com.growthstudio.roko -- -perf "$@" > $out 2>&1 &
pid=$!; /bin/sleep $secs; kill $pid 2>/dev/null; wait $pid 2>/dev/null; /bin/sleep 2
grep -E 'WALL|REFUSED|PERF|NAV|ERROR|rror:' $out | cut -c1-500; rm -f $out
