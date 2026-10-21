#!/bin/bash
# Stop.command — stops every camera's services; they stay stopped until Start.command or next login.
set -u
. "$(dirname "$0")/lib.sh"
for p in "$AGENTS/$LABEL_BASE".*.plist; do
  [ -f "$p" ] || continue
  launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null && echo "stopped $(basename "$p" .plist)" || echo "$(basename "$p" .plist) was not running"
done
# ffmpeg pipelines outlive the proxy (own process groups); sweep them so the cameras free their RTSP slots
sleep 1; pkill -KILL -f "ffmpeg -nostdin .*rtsp://" 2>/dev/null && echo "killed leftover ffmpeg pipelines"
pkill -KILL -f "mediamtx" 2>/dev/null && echo "killed leftover relay"
pause
