#!/bin/zsh
# One pass: pushes the plan unless the folder shows it was already under way, runs it, comes back
# after a runner failure and carries on, pulls what's on the phone. Exit 3: Screen Time. Exit 4: locked.
P=${REAL_WORK:-$HOME/roko-real-sites}; D=${DEVICE:?set DEVICE to your iPhone id}; RUN=com.growthstudio.realbench.ui.xctrunner
mkdir -p $P/real; out=$1; plan=$2; XR=$(ls $P/real/dd/Build/Products/*.xctestrun); work=$(mktemp -d); mkdir -p $out
push() { xcrun devicectl device copy to --device $D --domain-type appDataContainer --domain-identifier $RUN --source $1 --destination Documents/$2 >/dev/null 2>&1; }
pull() { xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $RUN --source Documents --destination $out >/dev/null 2>&1; }
want=$(python3 -I -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" $plan)
if [[ ! -f $out/started ]]; then
  # devicectl skips a file whose size and date match what's there, so the date must differ.
  touch $plan; push $plan plan.json || { echo "plan not pushed"; exit 1; }; touch $P/real/clear; push $P/real/clear clear
  pulled=$(mktemp -d); xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $RUN --source Documents/plan.json --destination $pulled/plan.json >/dev/null 2>&1
  cmp -s $plan $pulled/plan.json || { echo "plan on the phone doesn't match $plan"; exit 1; }
  touch $out/started
fi
for attempt in {1..16}; do
  rm -rf $work/r.xcresult
  xcodebuild test-without-building -xctestrun $XR -destination id=$D -resultBundlePath $work/r.xcresult -test-timeouts-enabled NO > $out/xcodebuild-$attempt.log 2>&1 &
  xb=$!
  while kill -0 $xb 2>/dev/null; do
    sleep 30
    if [[ $(xcrun devicectl device info lockState --device $D 2>/dev/null) != *"passcodeRequired: false"* ]]; then
      echo "locked at $(date +%H:%M)"; kill $xb 2>/dev/null; wait $xb 2>/dev/null; pull; exit 4
    fi
  done
  wait $xb
  pull
  [[ -f $out/blocked.txt ]] && { echo "Screen Time blocked $(cat $out/blocked.txt) at $(date +%H:%M)"; xcrun devicectl device copy to --device $D --domain-type appDataContainer --domain-identifier $RUN --source $P/real/clear --destination Documents/blocked.txt >/dev/null 2>&1; exit 3; }
  # Only this plan's ids count: a progress file left from another pass isn't this one's.
  have=$(python3 -I -c "import json,sys;d=set(open(sys.argv[2]).read().split());print(sum(x['id'] in d for x in json.load(open(sys.argv[1]))))" $plan $out/progress.txt 2>/dev/null || echo 0)
  if grep -q 'enabling automation mode' $out/xcodebuild-$attempt.log && [[ $have == 0 ]]; then echo "$(basename $out): automation mode timed out at $(date +%H:%M), offering it again: the phone may be asking for its passcode"; sleep 8; continue; fi
  [[ -f $out/progress.txt && $have -ge $want ]] && { echo "$(basename $out): done, $have of $want, $(date +%H:%M), attempt $attempt"; rm -rf $work; exit 0; }
  echo "$(basename $out): attempt $attempt ended at ${have} of $want, $(grep -m1 -E 'encountered an error|Terminating app' $out/xcodebuild-$attempt.log | cut -c1-150)"
  sleep 8
done
rm -rf $work; echo "$(basename $out): gave up"; exit 1
