#!/bin/sh
# probe.sh <camera-ip> <user> <password>
# Run on any machine on the camera's LAN (the N100 itself is ideal). Prints the camera's real
# stream specs and checks the ports the bridge needs, then the .env lines to paste.
# Needs: ffprobe (apt install ffmpeg), curl, nc. Password is never printed.
set -u
IP="${1:?usage: probe.sh <camera-ip> <user> <password>}"; U="${2:?}"; P="${3:?}"
probe() { ffprobe -v error -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name,width,height,avg_frame_rate -of csv=p=0 "rtsp://$U:$P@$IP:554/$1" 2>/dev/null; }
port() { nc -z -w 3 "$IP" "$1" >/dev/null 2>&1 && echo "open" || echo "CLOSED"; }
echo "== ports"; for p in 554 80 443 8000 9000; do printf "  %-5s %s\n" "$p" "$(port $p)"; done
echo "  (554 RTSP, 443/80 HTTP API + snapshots, 9000 Baichuan = push events + moving boxes)"
echo "== streams (codec,width,height,fps)"
M="$(probe h264Preview_01_main)"; S="$(probe h264Preview_01_sub)"
echo "  main: ${M:-NOT REACHABLE (is RTSP enabled on the camera?)}"; echo "  sub:  ${S:-NOT REACHABLE}"
echo "== snapshot"; code=$(curl -sk -o /dev/null -w '%{http_code}' "https://$IP/cgi-bin/api.cgi?cmd=Snap&channel=0&rs=probe&user=$U&password=$P"); echo "  HTTPS Snap: HTTP $code $( [ "$code" = 200 ] && echo ok || echo '(check user/password, or try http://)')"
echo "== AI state"; curl -sk "https://$IP/cgi-bin/api.cgi?cmd=GetAiState&channel=0&user=$U&password=$P" | tr -d ' \n' | grep -o '"value":{[^}]*' | head -1 | cut -c1-120; echo
fps() { echo "$1" | awk -F, '{split($4,a,"/"); if (a[2]>0) printf "%d", a[1]/a[2]; else print "?"}'; }
if [ -n "$M" ] && [ -n "$S" ]; then
  echo "== paste into .env"
  echo "HI_WIDTH=$(echo "$M" | cut -d, -f2)"; echo "HI_HEIGHT=$(echo "$M" | cut -d, -f3)"; echo "HI_FPS=$(fps "$M")"
  echo "LO_WIDTH=$(echo "$S" | cut -d, -f2)"; echo "LO_HEIGHT=$(echo "$S" | cut -d, -f3)"; echo "LO_FPS=$(fps "$S")"
  case "$M" in hevc*) echo "# main is H.265: full-quality path (iGPU transcodes the sub stream)";; h264*) echo "# main is H.264: set --hi-codec h264 and drop --lo-h265-transcode in the compose";; esac
fi
echo "== host iGPU (run on the N100 itself)"; [ -e /dev/dri/renderD128 ] && echo "  /dev/dri/renderD128 present$(command -v vainfo >/dev/null && vainfo 2>/dev/null | grep -c HEVC | sed 's/^/, vainfo HEVC entries: /')" || echo "  no /dev/dri on this machine (fine if this is a laptop; must exist on the N100)"
