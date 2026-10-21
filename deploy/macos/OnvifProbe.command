#!/bin/bash
# OnvifProbe.command — for every onvif camera: connects to its ONVIF event stream and records
# every event it publishes for 90 s into logs/onvif-<camera>.txt. Walk/drive in front of the
# cameras while it runs. Shows which detections the firmware actually emits.
set -u
. "$(dirname "$0")/lib.sh"
load_env
mkdir -p "$PROJECT_DIR/logs"
PY="$VENV/bin/python"; [ -x "$PY" ] || die "venv missing — run Install.command"
pkill -f onvif_sidecar.py 2>/dev/null && echo "stopped earlier probes"
pids=()
for cam in $(list_cameras); do
  load_camera "$cam"
  [ "${CAM_TYPE:-rtsp}" = "onvif" ] || continue
  out="$PROJECT_DIR/logs/onvif-$cam.txt"
  say "$cam -> $out"
  "$PY" "$PROJECT_DIR/onvif_sidecar.py" --host "$CAM_IP" --port "${ONVIF_PORT:-2020}" --user "$CAM_USER" --password "$CAM_PASS" --sink "http://127.0.0.1:${AI_SINK_PORT:-7999}/detections" --dump 90 > "$out" 2>&1 &
  pids+=($!)
done
[ ${#pids[@]} -gt 0 ] || die "no onvif cameras defined"
echo "recording for 90 s — go wave at the cameras…"
wait "${pids[@]}"
for cam in $(list_cameras); do [ -f "$PROJECT_DIR/logs/onvif-$cam.txt" ] && { echo; echo "== $cam"; grep -c EVENT "$PROJECT_DIR/logs/onvif-$cam.txt" | sed 's/^/events: /'; grep -v "EVENT" "$PROJECT_DIR/logs/onvif-$cam.txt" | tail -3; grep EVENT "$PROJECT_DIR/logs/onvif-$cam.txt" | sed 's/.*topic=//' | sort | uniq -c | sort -rn | head -12; }; done
pause
