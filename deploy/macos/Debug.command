#!/bin/bash
# Debug.command — toggles verbose (-v) logging for every camera and restarts its service.
# Run once to turn on, again to turn off. Then DumpLogs.command to read the result.
set -u
. "$(dirname "$0")/lib.sh"
for cam in $(list_cameras); do
  f="$CAMDIR/$cam.env"
  if grep -q '^EXTRA_ARGS=-v' "$f"; then sed -i '' 's/^EXTRA_ARGS=.*/EXTRA_ARGS=/' "$f"; echo "$cam: debug OFF"
  else sed -i '' 's/^EXTRA_ARGS=.*/EXTRA_ARGS=-v/' "$f"; echo "$cam: debug ON"; fi
  launchctl kickstart -k "gui/$(id -u)/$(label_proxy "$cam")" 2>/dev/null && echo "  restarted"
done
sleep 2
