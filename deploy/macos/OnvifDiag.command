#!/bin/bash
# OnvifDiag.command — stops any running ONVIF probes/sidecars, then tries several PullMessages
# request styles against the FIRST onvif camera and writes what the camera answers to
# logs/onvif-diag.txt. Diagnostic only.
set -u
. "$(dirname "$0")/lib.sh"
load_env
mkdir -p "$PROJECT_DIR/logs"
pkill -f onvif_sidecar.py 2>/dev/null && echo "stopped running probes/sidecars"
for cam in $(list_cameras); do
  load_camera "$cam"; [ "${CAM_TYPE:-rtsp}" = "onvif" ] || continue
  say "$cam ($CAM_IP)"
  "$VENV/bin/python" "$PROJECT_DIR/onvif_diag.py" --host "$CAM_IP" --port "${ONVIF_PORT:-2020}" --user "$CAM_USER" --password "$CAM_PASS" 2>&1 | tee "$PROJECT_DIR/logs/onvif-diag.txt"
  break
done
pause
