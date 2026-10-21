#!/bin/bash
# Test.command — runs ONE camera's proxy in THIS window so you can watch it adopt. Pauses that
# camera's service first. Ctrl-C to quit, then Start.command hands it back to launchd.
set -u
. "$(dirname "$0")/lib.sh"
load_env
check_env || die "fix .env first (EditConfig.command)"
cam="$(pick_camera "${1:-}")"
load_camera "$cam"
check_camera || die "fix $CAMDIR/$cam.env (EditConfig.command)"
for l in "$(label_proxy "$cam")" "$(label_sidecar "$cam")"; do
  agent_loaded "$l" && launchctl bootout "gui/$(id -u)" "$AGENTS/$l.plist" 2>/dev/null && echo "paused service $l"
done
if { [ "${CAM_TYPE:-rtsp}" = "reolink" ] || [ "${CAM_TYPE:-rtsp}" = "onvif" ]; }; then
  say "starting detection sidecar in the background"
  "$PROJECT_DIR/run-sidecar.sh" "$cam" > "$LOGDIR/$cam-sidecar-test.log" 2>&1 &
  SIDE=$!; trap 'kill $SIDE 2>/dev/null' EXIT
fi
say "starting proxy for $cam (watch for adoption lines, then adopt the camera in Protect)"
"$PROJECT_DIR/run-proxy.sh" "$cam"
