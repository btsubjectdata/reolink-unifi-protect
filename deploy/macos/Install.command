#!/bin/bash
# Install.command — double-click on the Mac mini. Safe to re-run (it updates in place).
#   1. Homebrew + python@3.12, node, ffmpeg (Homebrew's ffmpeg has VideoToolbox built in)
#   2. clones/updates woutersteegers/reolink-unifi-protect into ~/reolink-unifi-protect/src
#   3. applies the VideoToolbox patch (Mac media engine instead of Intel QSV)
#   4. python venv + the proxy, npm install for the AI sidecar
#   5. client certificate the proxy uses to authenticate to Protect
#   6. .env in ~/Library/Application Support/reolink-unifi-protect (from .env.example)
#   7. keeps the Mac awake (always-on host)
# It does NOT start anything. Next: EditConfig.command -> Probe.command -> Test.command.
set -u
. "$(dirname "$0")/lib.sh"
mkdir -p "$RUNTIME" "$SUPPORT" "$LOGDIR"
exec > >(tee -a "$LOGDIR/install.log") 2>&1
echo "===== Install  $(date) ====="
echo "this Mac: $(scutil --get LocalHostName 2>/dev/null || hostname -s)  ($(sysctl -n hw.model 2>/dev/null), $(uname -m))  macOS $(sw_vers -productVersion 2>/dev/null)"

# ---------------------------------------------------------------- 1. homebrew + packages
say "1/7  Homebrew packages"
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is not installed. Installing it (you will be asked for your Mac password)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || die "Homebrew install failed"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi
for pkg in python@3.12 node ffmpeg@6 git mediamtx; do
  if brew list --versions "$pkg" >/dev/null 2>&1; then
    echo "  $pkg: present ($(brew list --versions "$pkg" | head -1))"
  else
    echo "  $pkg: installing…"
    brew install "$pkg" || die "brew install $pkg failed"
  fi
done
echo "  ffmpeg in use: $(command -v ffmpeg) ($(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}'))"
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q hevc_videotoolbox \
  && echo "  ffmpeg: hevc_videotoolbox available" \
  || warn "  ffmpeg has no hevc_videotoolbox encoder — LO_TRANSCODE will not work; check 'which ffmpeg'"
command -v nc >/dev/null 2>&1 || die "nc (netcat) missing — it ships with macOS, something is very wrong"

# ---------------------------------------------------------------- 2. source
say "2/7  source  ->  $SRC"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch -q origin && git -C "$SRC" reset -q --hard origin/main && echo "  updated to $(git -C "$SRC" log -1 --format='%h %cd' --date=short)"
else
  git clone -q "$REPO_URL" "$SRC" || die "git clone failed"
  echo "  cloned $(git -C "$SRC" log -1 --format='%h %cd' --date=short)"
fi

# ---------------------------------------------------------------- 3. python
say "3/7  python"
PY="$(python_bin)" || die "no Python >= 3.12 found even after brew install python@3.12"
echo "  $PY ($("$PY" --version 2>&1))"
# (the VideoToolbox / Protect 7 changes live in this fork's source; nothing to patch)

# ---------------------------------------------------------------- 4. venv + sidecar
say "4/7  python venv + proxy"
if [ ! -x "$VENV/bin/python" ]; then
  "$PY" -m venv "$VENV" || die "venv creation failed"
fi
"$VENV/bin/pip" install -q --upgrade pip wheel setuptools
# pillow: reolinkapi prints "ImportError No module named 'PIL'" at import time without it (harmless, but noisy)
"$VENV/bin/pip" install -q "$SRC" pillow 2>&1 | grep -v "asyncio-mqtt\|aiomqtt\|sbtinstruments" || true
[ -x "$VENV/bin/unifi-cam-proxy" ] || die "pip install of the proxy failed (scroll up for the error)"
"$VENV/bin/unifi-cam-proxy" --version && echo "  proxy installed in $VENV"
grep -q -- "--transcode-backend" "$SRC/unifi/cams/base.py" && echo "  VideoToolbox backend present in base.py" || warn "  VideoToolbox backend NOT in base.py — wrong repo? REPO_URL must point at the btsubjectdata fork"

say "     AI sidecar (npm)"
( cd "$SIDECAR" && npm install --silent --no-audit --no-fund ) || die "npm install failed in $SIDECAR"
echo "  sidecar ready"

# ---------------------------------------------------------------- 5. cert
say "5/7  client certificate"
if [ -f "$CERT" ]; then
  echo "  keeping existing $CERT (delete it to regenerate)"
else
  T="$(mktemp -d)"
  openssl ecparam -out "$T/pk.key" -name prime256v1 -genkey -noout \
  && openssl req -new -sha256 -key "$T/pk.key" -out "$T/s.csr" \
       -subj "/C=TW/L=Taipei/O=Ubiquiti Networks Inc./OU=devint/CN=camera.ubnt.dev/emailAddress=support@ubnt.com" \
  && openssl x509 -req -sha256 -days 36500 -in "$T/s.csr" -signkey "$T/pk.key" -out "$T/pub.key" 2>/dev/null \
  && cat "$T/pk.key" "$T/pub.key" > "$CERT" && chmod 600 "$CERT" && rm -rf "$T" \
  && echo "  generated $CERT" || die "openssl failed"
fi

# ---------------------------------------------------------------- 6. config
say "6/7  config"
mkdir -p "$CAMDIR"
if [ -f "$ENV_FILE" ]; then
  echo "  keeping existing $ENV_FILE"
else
  cp "$PROJECT_DIR/.env.example" "$ENV_FILE" && chmod 600 "$ENV_FILE"
  echo "  created $ENV_FILE from .env.example — fill it in with EditConfig.command"
fi
cp "$PROJECT_DIR"/cameras/example-*.env "$CAMDIR/" && chmod 600 "$CAMDIR"/*.env
if [ -z "$(list_cameras)" ]; then
  echo "  no cameras yet: copy $CAMDIR/example-tapo.env (or example-reolink.env) to $CAMDIR/<name>.env"
else
  echo "  cameras: $(list_cameras | tr '\n' ' ')"
fi
chmod +x "$PROJECT_DIR"/*.command "$PROJECT_DIR"/*.sh 2>/dev/null

# ---------------------------------------------------------------- 7. always-on
say "7/7  keep the Mac awake"
if pmset -g 2>/dev/null | grep -Eq '^ *sleep +0( |$)'; then
  echo "  already set (sleep=0)"
else
  echo "  (asks for your password once) sleep=off, disk sleep=off, wake on LAN, auto-restart after power loss"
  sudo pmset -a sleep 0 disksleep 0 womp 1 autorestart 1 2>/dev/null && echo "  pmset OK" || warn "  pmset skipped — set 'Prevent automatic sleeping' in System Settings > Energy"
fi
sntp -sS time.apple.com >/dev/null 2>&1 && echo "  clock synced (Protect drops frames if the clock drifts > ~1 s)"

say "Installed. Next steps:"
echo "  1. EditConfig.command   — NVR IP, a local Protect user, camera IP + password"
echo "  2. Probe.command        — reads the camera's real resolution/codec/fps; copy its numbers into .env"
echo "  3. Test.command         — runs the proxy in this window; adopt the camera in Protect"
echo "  4. InstallService.command — makes it run at boot and restart itself"
pause
