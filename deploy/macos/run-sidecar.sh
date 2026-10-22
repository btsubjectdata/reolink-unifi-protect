#!/bin/bash
# run-sidecar.sh <camera> — the smart-detection sidecar for ONE camera, in the foreground:
#   onvif   -> onvif_sidecar.py (camera's own detections over ONVIF events)
#   reolink -> deploy/ai-sidecar (Node, Baichuan protocol, moving boxes)
# Both post to the proxy's sink at http://127.0.0.1:$AI_SINK_PORT/detections.
set -u
. "$(dirname "$0")/lib.sh"
[ -n "${1:-}" ] || { fail "usage: run-sidecar.sh <camera-name>"; exit 1; }
load_env
load_camera "$1"
mkdir -p "$LOGDIR"
export SINK_URL="http://127.0.0.1:${AI_SINK_PORT:-7999}/detections"
case "${CAM_TYPE:-rtsp}" in
  onvif)
    PY="$VENV/bin/python"; [ -x "$PY" ] || { fail "venv missing — run Install.command"; exit 1; }
    SIDE="$(dirname "$0")/onvif_sidecar.py"; [ -f "$SIDE" ] || SIDE="$PROJECT_DIR/onvif_sidecar.py"
    echo "[$(date '+%F %T')] [$CAM] starting onvif sidecar -> $CAM_IP:${ONVIF_PORT:-2020}, sink $SINK_URL"
    exec "$PY" "$SIDE" --host "$CAM_IP" --port "${ONVIF_PORT:-2020}" --user "$CAM_USER" --password "$CAM_PASS" --sink "$SINK_URL" --snapshot-port "${SNAPSHOT_PORT:-$(( ${AI_SINK_PORT:-7999} + 1000 ))}" --snapshot-file "$SNAPDIR/$CAM.jpg" --hold "${ONVIF_HOLD:-5}"
    ;;
  reolink)
    [ -d "$SIDECAR/node_modules" ] || { fail "sidecar not installed — run Install.command"; exit 1; }
    command -v node >/dev/null 2>&1 || { fail "node not found (brew install node)"; exit 1; }
    export CAM_IP CAM_USER CAM_PASS
    cd "$SIDECAR" || exit 1
    echo "[$(date '+%F %T')] [$CAM] starting reolink ai-sidecar -> camera $CAM_IP, sink $SINK_URL"
    exec node index.mjs
    ;;
  *) echo "[$CAM] CAM_TYPE=${CAM_TYPE:-rtsp}: no sidecar needed"; exit 0;;
esac
