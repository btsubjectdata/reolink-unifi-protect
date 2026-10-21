#!/bin/bash
# Logs.command — follows every camera's log live. Ctrl-C (or close the window) to stop.
set -u
. "$(dirname "$0")/lib.sh"
mkdir -p "$LOGDIR"
files=()
for cam in $(list_cameras); do touch "$LOGDIR/$cam-proxy.log"; files+=("$LOGDIR/$cam-proxy.log"); [ -f "$LOGDIR/$cam-sidecar.log" ] && files+=("$LOGDIR/$cam-sidecar.log"); done
echo "following ${files[*]} — Ctrl-C to stop"
tail -n 30 -F "${files[@]}"
