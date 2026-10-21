#!/bin/bash
# Shared paths + helpers for every reolink-unifi-protect script. Sourced, not run.
#
#   <this folder>                       scripts + docs (deploy/macos of the repo, copied anywhere, e.g. ~/Documents)
#   ~/reolink-unifi-protect             runtime: git checkout, python venv, node_modules (NOT synced)
#   ~/Library/Application Support/reolink-unifi-protect   .env (NVR) + cameras/<name>.env + client.pem
#   ~/Library/Logs/reolink-unifi-protect                  logs, one per camera
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$HOME/reolink-unifi-protect"
SRC="$RUNTIME/src"
VENV="$RUNTIME/venv"
SIDECAR="$SRC/deploy/ai-sidecar"
SUPPORT="$HOME/Library/Application Support/reolink-unifi-protect"
ENV_FILE="$SUPPORT/.env"
CAMDIR="$SUPPORT/cameras"
CERT="$SUPPORT/client.pem"
LOGDIR="$HOME/Library/Logs/reolink-unifi-protect"
SNAPDIR="$RUNTIME/snapshots"   # per-camera JPEG kept fresh by the stream ffmpeg (--snapshot-tee)
RELAY_PORT=8554                # local RTSP relay (mediamtx): one session per camera stream, any number of readers
RELAY_CFG="$RUNTIME/relay.yml"
LABEL_BASE="io.github.reolink-unifi-protect"
AGENTS="$HOME/Library/LaunchAgents"
REPO_URL="${REPO_URL:-https://github.com/btsubjectdata/reolink-unifi-protect.git}"   # this fork (macOS + Protect 7 fixes)

# Homebrew lives in different places on Apple Silicon vs Intel; make both visible.
# ffmpeg@6 first: Protect's FLV ingest drops streams muxed by ffmpeg 7+/9 (keg-only formula,
# so it is not on the default PATH).
FFMPEG_KEG="/opt/homebrew/opt/ffmpeg@6/bin:/usr/local/opt/ffmpeg@6/bin"
export PATH="$FFMPEG_KEG:/opt/homebrew/bin:/opt/homebrew/opt/python@3.12/bin:/usr/local/bin:/usr/local/opt/python@3.12/bin:$PATH"

say()   { printf "\n\033[1m%s\033[0m\n" "$*"; }
warn()  { printf "\033[33m%s\033[0m\n" "$*"; }
fail()  { printf "\033[31mERROR: %s\033[0m\n" "$*"; }
pause() { read -r -p "Press Return to close." _; }
die()   { fail "$*"; pause; exit 1; }

# NVR-level settings.
load_env() {
  [ -f "$ENV_FILE" ] || die "no config at $ENV_FILE — run Install.command first, then EditConfig.command"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

# Camera names = cameras/*.env minus the example-* files.
list_cameras() {
  local f
  for f in "$CAMDIR"/*.env; do
    [ -f "$f" ] || continue
    f="$(basename "$f" .env)"
    case "$f" in example-*) continue;; esac
    echo "$f"
  done
}

# Loads cameras/<name>.env on top of .env. Sets CAM (the name).
load_camera() {
  CAM="$1"
  local f="$CAMDIR/$CAM.env"
  [ -f "$f" ] || die "no camera config $f (cameras: $(list_cameras | tr '\n' ' '))"
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

# Pick a camera: argument, or if there is exactly one, that one, else ask.
pick_camera() {
  if [ -n "${1:-}" ]; then echo "$1"; return; fi
  local cams; cams="$(list_cameras)"
  local n; n="$(echo "$cams" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then die "no cameras defined in $CAMDIR — copy an example-*.env to <name>.env"; fi
  if [ "$n" -eq 1 ]; then echo "$cams"; return; fi
  echo "cameras: $(echo "$cams" | tr '\n' ' ')" >&2
  read -r -p "which camera? " c
  echo "$c"
}

check_env() {
  local missing=0 k
  for k in NVR_IP; do
    if [ -z "${!k:-}" ]; then fail "$k is empty in $ENV_FILE"; missing=1; fi
  done
  if [ -z "${ADOPTION_TOKEN:-}" ] && { [ -z "${NVR_USER:-}" ] || [ -z "${NVR_PASS:-}" ]; }; then
    fail "set NVR_USER + NVR_PASS (recommended) or ADOPTION_TOKEN in $ENV_FILE"; missing=1
  fi
  return $missing
}

check_camera() {
  local missing=0 k
  for k in CAM_IP CAM_USER CAM_PASS CAM_NAME CAM_MAC HI_PATH LO_PATH HI_CODEC HI_WIDTH HI_HEIGHT HI_FPS LO_CODEC LO_WIDTH LO_HEIGHT LO_FPS; do
    if [ -z "${!k:-}" ]; then fail "$k is empty in $CAMDIR/$CAM.env"; missing=1; fi
  done
  return $missing
}

python_bin() {
  local p
  for p in "$VENV/bin/python" python3.12 python3.13 python3; do
    if command -v "$p" >/dev/null 2>&1; then
      if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' 2>/dev/null; then
        command -v "$p"; return 0
      fi
    fi
  done
  return 1
}

# Percent-encode a credential for use inside an rtsp:// URL (handles @ # : / ? ! etc).
urlenc() {
  local py="$VENV/bin/python"; [ -x "$py" ] || py="$(python_bin)" || py=python3
  "$py" -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}
# rtsp://user:pass@ip:554 with the credentials encoded; needs CAM_* loaded.
rtsp_base() { echo "rtsp://$(urlenc "$CAM_USER"):$(urlenc "$CAM_PASS")@${CAM_IP}:554"; }
# Hide credentials in anything we print.
mask_url() { sed -E 's#(rtsp://).*@#\1***:***@#'; }

label_relay()   { echo "$LABEL_BASE.relay"; }
# RELAY=1 (default): the proxy reads rtsp://127.0.0.1:$RELAY_PORT/<cam>-hi|-lo instead of the camera.
relay_on()      { [ "${RELAY:-1}" = "1" ]; }
label_proxy()   { echo "$LABEL_BASE.$1.proxy"; }
label_sidecar() { echo "$LABEL_BASE.$1.sidecar"; }
agent_loaded()  { launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1; }
agent_pid()     { launchctl print "gui/$(id -u)/$1" 2>/dev/null | sed -n 's/.*pid = \([0-9]*\).*/\1/p' | head -1; }
