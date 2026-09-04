#!/usr/bin/env bash
# Evaluate a script in the running app and print the answer.
#
# The app watches /tmp/native-eval and fires when its modification time moves,
# so two evaluations inside the same second look like one and the second read
# returns the previous answer. Every call therefore stamps a unique comment
# into the script and waits for the result file to be recreated.
#
#   ./probe-native.sh 'document.title'
set -u
P=$(cd "$(dirname "$0")/.." && pwd)
. "$P/tools/device.sh"

SCRIPT=${1:?usage: probe-native.sh <javascript>}
STAMP=$(date +%s)-$RANDOM

device_run 60 "
rm -f /tmp/native-eval-result
printf '%s\n' '$SCRIPT /*$STAMP*/' > /tmp/native-eval
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ -f /tmp/native-eval-result ] && { cat /tmp/native-eval-result; exit 0; }
  sleep 2
done
echo '(no answer)'
" 2>/dev/null
