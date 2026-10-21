#!/bin/bash
# run-proxy.sh <camera> — runs the UniFi camera proxy for ONE camera in the foreground.
# Used by launchd (InstallService.command) and by Test.command.
set -u
. "$(dirname "$0")/lib.sh"
[ -n "${1:-}" ] || { fail "usage: run-proxy.sh <camera-name>"; exit 1; }
load_env
load_camera "$1"
check_env || exit 1
check_camera || exit 1
[ -f "$CERT" ] || { fail "no client cert at $CERT — run Install.command"; exit 1; }
[ -x "$VENV/bin/unifi-cam-proxy" ] || { fail "proxy not installed in $VENV — run Install.command"; exit 1; }

RTSP_BASE="$(rtsp_base)"
# Protect asks a G5 Pro for three streams (video1 high, video2 medium, video3 low). Pulling each
# straight from the camera is three RTSP sessions; a Tapo allows two, so streams fight and Protect
# hangs them up every few seconds. With RELAY=1 the proxy reads the local mediamtx relay instead,
# which holds exactly one session per camera stream (run-relay.sh).
if relay_on; then
  RTSP_BASE="rtsp://127.0.0.1:$RELAY_PORT"
  HI_PATH="$CAM-hi"; LO_PATH="$CAM-lo"
fi
FFMPEG_PAT="ffmpeg -nostdin .*(@${CAM_IP}:554/|:${RELAY_PORT}/${CAM}-)"

ARGS=(
  --host "$NVR_IP"
  --cert "$CERT"
  --mac "$CAM_MAC"
  --ip "$CAM_IP"
  --name "$CAM_NAME"
  --model "${MODEL:-UVC G5 Pro}"
  --sysid "${SYSID:-0xa598}"
  --platform "${PLATFORM:-sav837gw}"
  --fw-version "${FW_VERSION:-5.4.132}"
  --fw-build "${FW_BUILD:-92ebf37.260724.1639}"
)
if [ -n "${ADOPTION_TOKEN:-}" ]; then
  ARGS+=(--token "$ADOPTION_TOKEN")
else
  ARGS+=(--nvr-username "$NVR_USER" --nvr-password "$NVR_PASS")
fi
# shellcheck disable=SC2206
ARGS+=(${EXTRA_ARGS:-})

ARGS+=(
  rtsp
  -s "$RTSP_BASE/$HI_PATH" "$RTSP_BASE/$LO_PATH"
  --rtsp-transport "${RTSP_TRANSPORT:-tcp}"
  --ffmpeg-args "${FFMPEG_ARGS:--c:v copy -ar 32000 -ac 1 -codec:a aac -b:a 32k}"
  --hi-codec "$HI_CODEC" --hi-width "$HI_WIDTH" --hi-height "$HI_HEIGHT" --hi-fps "$HI_FPS"
  --lo-codec "$LO_CODEC" --lo-width "$LO_WIDTH" --lo-height "$LO_HEIGHT" --lo-fps "$LO_FPS"
  --transcode-backend videotoolbox
)
if [ -z "${SNAPSHOT_URL:-}" ] && [ "${CAM_TYPE:-rtsp}" = "reolink" ]; then
  SNAPSHOT_URL="https://${CAM_IP}/cgi-bin/api.cgi?cmd=Snap&channel=0&rs=proxy&user=$(urlenc "$CAM_USER")&password=$(urlenc "$CAM_PASS")"
fi
if [ -z "${SNAPSHOT_URL:-}" ] && [ "${CAM_TYPE:-rtsp}" = "onvif" ]; then
  # served by onvif_sidecar.py from the camera's ONVIF snapshot: saves an RTSP session
  SNAPSHOT_URL="http://127.0.0.1:${SNAPSHOT_PORT:-$(( ${AI_SINK_PORT:-7999} + 1000 ))}/snapshot.jpg"
fi
[ -n "${SNAPSHOT_URL:-}" ] && ARGS+=(--snapshot-url "$SNAPSHOT_URL")
if [ "${LO_TRANSCODE:-0}" = "1" ]; then
  ARGS+=(--lo-h265-transcode --lo-transcode-bitrate "${LO_BITRATE:-1M}")
fi
case "${CAM_TYPE:-rtsp}" in
  reolink)
    ARGS+=(
      --reolink-ai-host "$CAM_IP" --reolink-ai-user "$CAM_USER" --reolink-ai-password "$CAM_PASS"
      --ai-sink-port "${AI_SINK_PORT:-7999}"
      --ai-min-confidence "${AI_MIN_CONFIDENCE:-0.75}"
      --ai-classes "${AI_CLASSES:-person,vehicle,animal}"
    )
    [ -n "${AI_CONFIDENCE_OVERRIDES:-}" ] && ARGS+=(--ai-confidence-overrides "$AI_CONFIDENCE_OVERRIDES")
    ;;
  onvif)
    # Event-level detections arrive as one fixed box per class from onvif_sidecar.py, so the
    # proxy's "never moved" filter must be off. Snapshots come from the sub-stream ffmpeg
    # (tee) and are served by the sidecar: no third RTSP session (Tapo allows two).
    mkdir -p "$SNAPDIR"
    ARGS+=(
      --snapshot-tee "$SNAPDIR/$CAM.jpg" --snapshot-tee-stream "${SNAPSHOT_TEE_STREAM:-video3}"
      --ai-sink-port "${AI_SINK_PORT:-7999}"
      --ai-min-movement 0
      --ai-min-confidence "${AI_MIN_CONFIDENCE:-0.5}"
      --ai-classes "${AI_CLASSES:-person,vehicle,animal}"
      # ONVIF events carry no position: sample frames for THUMBNAIL_DELAY seconds,
      # keep the one that changed most since the event fired and zoom on the
      # changed area (THUMBNAIL_CROP=frame for the whole frame letterboxed instead)
      --thumbnail-crop "${THUMBNAIL_CROP:-motion}"
      --thumbnail-delay "${THUMBNAIL_DELAY:-5}"
      # the camera's ONVIF push arrives a few seconds after it saw the subject:
      # start the event that much earlier so the clip includes the walk-in
      --event-lead "${EVENT_LEAD:-5}"
      # end the event soon after the camera stops reporting the subject (the sidecar
      # already holds each class ONVIF_HOLD s past its last notification)
      --ai-clear-after "${AI_CLEAR_AFTER:-1}"
    )
    ;;
esac

mkdir -p "$LOGDIR"
cd "$SRC" || exit 1
echo "[$(date '+%F %T')] [$CAM] starting proxy -> NVR $NVR_IP, camera $CAM_IP ($CAM_NAME, $HI_CODEC ${HI_WIDTH}x${HI_HEIGHT})$(relay_on && echo " via relay $RTSP_BASE")"
if relay_on && ! nc -z -w 2 127.0.0.1 "$RELAY_PORT" 2>/dev/null; then
  echo "[$CAM] relay not listening on 127.0.0.1:$RELAY_PORT yet — waiting"; for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 2; nc -z -w 2 127.0.0.1 "$RELAY_PORT" 2>/dev/null && break; done
fi
# ffmpeg prints the full RTSP URL (credentials included) in its own error lines; the proxy only
# redacts its own output. Mask everything on the way to the log.
exec > >(sed -E -u 's#(rtsp://)[^@/[:space:]"]+@#\1***:***@#g') 2>&1
# The proxy starts each ffmpeg pipeline in its own process group, so killing the proxy alone
# leaves ffmpeg streaming from the camera — and a Tapo only allows two RTSP sessions, so the
# orphans lock the next start out ("Operation not permitted"). Run the proxy as a child and
# take its whole tree down with it.
cleanup() {
  kill -TERM "$PID" 2>/dev/null
  pkill -TERM -f "$FFMPEG_PAT" 2>/dev/null
  sleep 1
  pkill -KILL -f "$FFMPEG_PAT" 2>/dev/null
  kill -KILL "$PID" 2>/dev/null
}
trap 'cleanup; exit 143' TERM INT HUP
# anything left over from an earlier run of this camera
pkill -KILL -f "$FFMPEG_PAT" 2>/dev/null && { echo "[$CAM] killed orphaned ffmpeg from a previous run; waiting for the camera to free the session"; sleep 8; }
# CONNECT_WITH_TOKEN=0 (camera file): --adopted, i.e. connect like an adopted camera without
# fetching an adoption token. Leave at 1 until the camera shows up in Protect.
if [ "${CONNECT_WITH_TOKEN:-1}" = "0" ]; then
  ARGS+=(--adopted)
  echo "[$CAM] connecting as an adopted camera (CONNECT_WITH_TOKEN=0)"
fi
"$VENV/bin/unifi-cam-proxy" "${ARGS[@]}" &
PID=$!
wait "$PID"
RC=$?
cleanup
exit $RC
