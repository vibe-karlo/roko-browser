#!/bin/zsh
P=${REAL_WORK:-$HOME/roko-real-sites}; W=$P/real/work; T=${0:A:h}
for pass in ${@:-first warm r1 r2 r3 scroll}; do
  echo "$pass started $(date +%H:%M)"
  zsh $T/pass.sh $W/passes/$pass $W/plan-$pass.json; code=$?
  [[ $code == 0 ]] || { echo "stopped in $pass with code $code at $(date +%H:%M)"; exit $code; }
done
echo "all passes done $(date +%H:%M)"
