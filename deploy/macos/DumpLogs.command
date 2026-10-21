#!/bin/bash
# DumpLogs.command — copies the last 4000 lines of every camera log into logs/ in this folder
# (credentials are already masked by the proxy) so they can be read/shared without opening Terminal.
set -u
. "$(dirname "$0")/lib.sh"
mkdir -p "$PROJECT_DIR/logs"
for f in "$LOGDIR"/*.log; do
  [ -f "$f" ] || continue
  tail -n 4000 "$f" | mask_url > "$PROJECT_DIR/logs/$(basename "$f")"
  echo "copied $(basename "$f") ($(wc -l < "$PROJECT_DIR/logs/$(basename "$f")" | tr -d ' ') lines)"
done
for cam in $(list_cameras); do
  { echo "== $cam agent"; launchctl print "gui/$(id -u)/$(label_proxy "$cam")" 2>&1 | grep -E "state|pid|last exit|runs" | head -6; echo "== ffmpeg"; pgrep -fl "ffmpeg.*$( . "$CAMDIR/$cam.env"; echo "$CAM_IP")" | mask_url | cut -c1-200; } > "$PROJECT_DIR/logs/$cam-status.txt" 2>&1
done
echo "done -> $PROJECT_DIR/logs"
sleep 2
