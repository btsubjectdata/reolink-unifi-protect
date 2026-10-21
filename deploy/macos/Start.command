#!/bin/bash
# Start.command — starts every camera's services (agents from InstallService.command).
set -u
. "$(dirname "$0")/lib.sh"
l="$(label_relay)"; p="$AGENTS/$l.plist"
if [ -f "$p" ]; then agent_loaded "$l" || launchctl bootstrap "gui/$(id -u)" "$p"; launchctl kickstart "gui/$(id -u)/$l" 2>/dev/null && echo "started $l"; sleep 3; fi
for cam in $(list_cameras); do
  for l in "$(label_proxy "$cam")" "$(label_sidecar "$cam")"; do
    p="$AGENTS/$l.plist"; [ -f "$p" ] || continue
    agent_loaded "$l" || launchctl bootstrap "gui/$(id -u)" "$p"
    launchctl kickstart "gui/$(id -u)/$l" 2>/dev/null && echo "started $l"
  done
done
sleep 3
for cam in $(list_cameras); do echo "--- $cam"; tail -5 "$LOGDIR/$cam-proxy.log" 2>/dev/null; done
pause
