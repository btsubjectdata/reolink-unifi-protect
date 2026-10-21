#!/bin/bash
# Status.command — per camera: service up? camera reachable? last log lines.
set -u
. "$(dirname "$0")/lib.sh"
[ -f "$ENV_FILE" ] && load_env
say "NVR $NVR_IP"
for port in 443 7442; do nc -z -w 2 "$NVR_IP" "$port" 2>/dev/null && echo "  OK    $NVR_IP:$port" || warn "  FAIL  $NVR_IP:$port"; done
l="$(label_relay)"
if [ -f "$AGENTS/$l.plist" ]; then
  say "relay  (mediamtx, 127.0.0.1:$RELAY_PORT)"
  pid="$(agent_pid "$l")"; [ -n "$pid" ] && echo "  UP    relay (pid $pid)" || warn "  DOWN  relay"
  nc -z -w 2 127.0.0.1 "$RELAY_PORT" 2>/dev/null && echo "  OK    listening" || warn "  FAIL  not listening"
  tail -4 "$LOGDIR/relay.log" 2>/dev/null | sed 's/^/    /'
fi
for cam in $(list_cameras); do
  load_camera "$cam"
  say "$cam  ($CAM_NAME, $CAM_IP)"
  l="$(label_proxy "$cam")"
  if agent_loaded "$l"; then
    pid="$(agent_pid "$l")"; [ -n "$pid" ] && echo "  UP    proxy (pid $pid)" || warn "  DOWN  proxy (loaded, no process)"
  else warn "  OFF   proxy (not installed/loaded)"; fi
  if { [ "${CAM_TYPE:-rtsp}" = "reolink" ] || [ "${CAM_TYPE:-rtsp}" = "onvif" ]; }; then
    l="$(label_sidecar "$cam")"; pid="$(agent_pid "$l")"
    [ -n "$pid" ] && echo "  UP    sidecar (pid $pid)" || warn "  DOWN  sidecar"
  fi
  nc -z -w 2 "$CAM_IP" 554 2>/dev/null && echo "  OK    $CAM_IP:554 rtsp" || warn "  FAIL  $CAM_IP:554 rtsp"
  echo "  ffmpeg workers: $(pgrep -f "ffmpeg.*($CAM_IP|:$RELAY_PORT/$cam-)" | wc -l | tr -d ' ')  (relay: ${RELAY:-1})"
  tail -6 "$LOGDIR/$cam-proxy.log" 2>/dev/null | sed 's/^/    /'
done
pause
