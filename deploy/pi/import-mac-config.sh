#!/bin/sh
# import-mac-config.sh <folder copied from the Mac>
# Converts the macOS kit's config (its .env + cameras/<name>.env + client.pem, from
# ~/Library/Application Support/reolink-unifi-protect on the Mac) into cameras/<name>.env files
# for this stack, keeping CAM_MAC so Protect keeps the cameras and their history.
set -eu
src="${1:?usage: import-mac-config.sh <folder with .env, cameras/, client.pem>}"
cd "$(dirname "$0")"
cp "$src/client.pem" ./client.pem && chmod 600 client.pem
nvr=$(grep -E '^(NVR_IP|NVR_USER|NVR_PASS)=' "$src/.env" | sed 's/"//g')
i=0
for f in "$src"/cameras/*.env; do
  n=$(basename "$f" .env); case "$n" in example-*) continue;; esac
  i=$((i+1)); out="cameras/$n.env"
  {
    echo "# imported from the Mac kit $(date +%F)"; echo "$nvr"
    grep -E '^(CAM_IP|CAM_USER|CAM_PASS|CAM_NAME|CAM_MAC|ONVIF_PORT|HI_PATH|LO_PATH|HI_CODEC|HI_WIDTH|HI_HEIGHT|HI_FPS|LO_CODEC|LO_WIDTH|LO_HEIGHT|LO_FPS|FFMPEG_ARGS|FW_VERSION|FW_BUILD|MODEL|SYSID|PLATFORM|AI_MIN_CONFIDENCE|AI_CLASSES|THUMBNAIL_CROP|THUMBNAIL_DELAY|EVENT_LEAD|ONVIF_HOLD|AI_CLEAR_AFTER)=' "$f" | sed 's/"//g'
    grep -q '^CONNECT_WITH_TOKEN=0' "$f" && echo "ADOPTED=1" || echo "ADOPTED=0"
    echo "RELAY_PORT=$((8553+i))"; echo "AI_SINK_PORT=$((8000-i))"; echo "SNAPSHOT_PORT=$((9000-i))"; echo "PUSH_PORT=$((10000-i))"
    echo "SNAPSHOT_TEE_KEYFRAMES=1"; echo "TZ=${TZ:-America/Chicago}"
  } > "$out"; chmod 600 "$out"; echo "wrote $out"
done
