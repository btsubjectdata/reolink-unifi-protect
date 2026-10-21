#!/bin/bash
# Probe.command — for every camera: checks reachability, asks the camera what it really sends on the
# main and sub RTSP streams (codec, resolution, fps, audio) and prints the <name>.env lines to use.
# Read-only; touches nothing in Protect.
set -u
. "$(dirname "$0")/lib.sh"
# ProbeApply.command (a copy of this script) writes the measured HI_*/LO_* values into each
# camera file instead of just reporting them.
APPLY=0; case "$(basename "$0")" in ProbeApply*) APPLY=1;; esac
load_env
command -v ffprobe >/dev/null 2>&1 || die "ffprobe not found — run Install.command"

say "NVR $NVR_IP"
for spec in "443 Protect API" "7442 Protect ingest"; do
  p="${spec%% *}"; nc -z -w 3 "$NVR_IP" "$p" 2>/dev/null && echo "  OK    $NVR_IP:$p  ${spec#* }" || warn "  FAIL  $NVR_IP:$p  ${spec#* }"
done

probe() {  # path -> prints "codec w h fps audio"
  local out codec w h fps audio
  out="$(ffprobe -v error -rtsp_transport "${RTSP_TRANSPORT:-tcp}" -select_streams v:0 \
          -show_entries stream=codec_name,width,height,r_frame_rate,avg_frame_rate \
          -of default=noprint_wrappers=1 "$RTSP_BASE/$1" 2>&1)"
  echo "$out" | grep -q codec_name || { echo "ERR $(echo "$out" | tail -1 | mask_url)"; return; }
  codec="$(echo "$out" | sed -n 's/^codec_name=//p')"; w="$(echo "$out" | sed -n 's/^width=//p')"; h="$(echo "$out" | sed -n 's/^height=//p')"
  fps="$(echo "$out" | sed -n 's/^avg_frame_rate=//p' | head -1)"; case "$fps" in */*) [ "${fps##*/}" != 0 ] && fps=$(( ${fps%%/*} / ${fps##*/} )) || fps=0;; esac
  [ "${fps:-0}" = "0" ] && fps="$(echo "$out" | sed -n 's/^r_frame_rate=//p' | awk -F/ '{printf "%d", $1/$2}')"
  case "$codec" in hevc) codec=h265;; esac
  audio="$(ffprobe -v error -rtsp_transport "${RTSP_TRANSPORT:-tcp}" -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$RTSP_BASE/$1" 2>/dev/null | head -1)"
  echo "$codec $w $h $fps ${audio:-none}"
}

for cam in $(list_cameras); do
  load_camera "$cam"
  say "$cam  ($CAM_NAME, $CAM_IP, type ${CAM_TYPE:-rtsp})"
  for spec in "554 RTSP" "443 HTTPS" "9000 Baichuan (Reolink AI)"; do
    p="${spec%% *}"
    if nc -z -w 3 "$CAM_IP" "$p" 2>/dev/null; then echo "  OK    $CAM_IP:$p  ${spec#* }"
    elif [ "$p" = 554 ] || [ "${CAM_TYPE:-rtsp}" = reolink ]; then warn "  FAIL  $CAM_IP:$p  ${spec#* }"; fi
  done
  [ -n "${CAM_PASS:-}" ] || { warn "  CAM_PASS empty — cannot probe streams"; continue; }
  RTSP_BASE="$(rtsp_base)"
  HI="$(probe "$HI_PATH")"; LO="$(probe "$LO_PATH")"
  echo "  main  $HI_PATH: $HI"
  echo "  sub   $LO_PATH: $LO"
  case "$HI" in ERR*)
    warn "  main stream unreadable — wrong HI_PATH or camera credentials?"
    case "$CAM_USER" in *@*) warn "  CAM_USER looks like an e-mail: Tapo RTSP needs the Camera Account (Tapo app > camera > Settings > Advanced > Camera Account), not the TP-Link cloud login";; esac
    continue;; esac
  set -- $HI; hc=$1; hw=$2; hh=$3; hf=$4; ha=$5
  set -- $LO; lc=${1:-?}; lw=${2:-?}; lh=${3:-?}; lf=${4:-?}
  echo "  measured -> config:"
  for pair in "HI_CODEC $hc $HI_CODEC" "HI_WIDTH $hw $HI_WIDTH" "HI_HEIGHT $hh $HI_HEIGHT" "HI_FPS $hf $HI_FPS" \
              "LO_WIDTH $lw $LO_WIDTH" "LO_HEIGHT $lh $LO_HEIGHT" "LO_FPS $lf $LO_FPS"; do
    set -- $pair
    if [ "$2" = "$3" ]; then echo "    $1=$2  ok"
    elif [ "$APPLY" = 1 ] && [ "$2" != "?" ]; then
      sed -i '' "s/^$1=.*/$1=$2/" "$CAMDIR/$cam.env" && echo "    $1=$2  (was $3 — UPDATED in $cam.env)"
    else warn "    $1=$2  (config says $3 — change it, or run ProbeApply.command)"; fi
  done
  if [ "$lc" = h265 ]; then echo "    LO_CODEC=h265 LO_TRANSCODE=0  (sub stream is already HEVC)"
  elif [ "$hc" = h265 ]; then echo "    LO_CODEC=h265 LO_TRANSCODE=1  (HEVC main; Mac re-encodes the H.264 sub stream)"
  else echo "    LO_CODEC=h264 LO_TRANSCODE=0  (H.264 camera; leave enhanced encoding OFF in Protect)"; fi
  case "$ha" in aac) echo "    audio is AAC: FFMPEG_ARGS=\"-c:v copy -c:a copy\" is fine";;
    none) echo "    no audio stream";;
    *) echo "    audio is $ha: keep FFMPEG_ARGS transcoding to aac (the default)";; esac
done
echo
echo "Fix any mismatches BEFORE adopting — Protect caches them at adoption."
pause
