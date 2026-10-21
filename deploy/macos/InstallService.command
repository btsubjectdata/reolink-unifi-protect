#!/bin/bash
# InstallService.command — double-click (re-run after adding/removing a camera file). Installs one
# launchd user agent per camera in cameras/*.env (plus a sidecar agent for Reolink cameras). They
# start at login and restart themselves if they die.
#   io.github.reolink-unifi-protect.<camera>.proxy
#   io.github.reolink-unifi-protect.<camera>.sidecar   (Reolink / ONVIF)
#   io.github.reolink-unifi-protect.relay              (mediamtx RTSP relay, one for all cameras)
# Logs: ~/Library/Logs/reolink-unifi-protect/<camera>-proxy.log
# NOTE: user agents run only while someone is logged in. Turn on automatic login for your
# account (System Settings > Users & Groups > Automatic login) so a reboot comes back up.
set -u
. "$(dirname "$0")/lib.sh"
load_env
check_env || die "fix .env first (EditConfig.command)"
[ -x "$VENV/bin/unifi-cam-proxy" ] || die "run Install.command first"
mkdir -p "$AGENTS" "$LOGDIR"
CAMS="$(list_cameras)"
[ -n "$CAMS" ] || die "no cameras in $CAMDIR — copy an example-*.env to <name>.env first"

BREW_PATH="$FFMPEG_KEG:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

write_agent() {  # label script camera logname
  local label="$1" script="$2" cam="$3" logname="$4" plist="$AGENTS/$1.plist"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$script</string><string>$cam</string></array>
  <key>WorkingDirectory</key><string>$SRC</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$BREW_PATH</string><key>HOME</key><string>$HOME</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOGDIR/$logname.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/$logname.log</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$plist" && echo "  loaded $label"
}

say "installing launchd agents"
# The scripts live in ~/Documents (iCloud); launchd jobs are blocked from ~/Documents by macOS
# privacy rules, so the runners are copied into the runtime dir and launched from there.
cp "$PROJECT_DIR/lib.sh" "$PROJECT_DIR/run-proxy.sh" "$PROJECT_DIR/run-sidecar.sh" "$PROJECT_DIR/run-relay.sh" "$PROJECT_DIR/onvif_sidecar.py" "$RUNTIME/"
chmod +x "$RUNTIME"/*.sh

# stop everything first so orphaned ffmpeg pipelines (own process groups) do not hold the cameras'
# RTSP slots when the new agents start
for p in "$AGENTS/$LABEL_BASE".*.plist; do [ -f "$p" ] && launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null; done
sleep 1; pkill -KILL -f "ffmpeg -nostdin .*rtsp://" 2>/dev/null && echo "  killed leftover ffmpeg pipelines"
pkill -KILL -f "unifi-cam-proxy|onvif_sidecar.py|mediamtx" 2>/dev/null
sleep 2

# RTSP relay first: the proxies read from it (RELAY=1, the default)
RELAY_NEEDED=0
for cam in $CAMS; do load_camera "$cam"; relay_on && RELAY_NEEDED=1; done
if [ "$RELAY_NEEDED" = 1 ]; then
  command -v mediamtx >/dev/null 2>&1 || die "mediamtx not installed — run Install.command (or set RELAY=0 in every camera file)"
  write_agent "$(label_relay)" "$RUNTIME/run-relay.sh" "" "relay"
  for _ in 1 2 3 4 5 6 7 8; do nc -z -w 1 127.0.0.1 "$RELAY_PORT" 2>/dev/null && break; sleep 1; done
  nc -z -w 1 127.0.0.1 "$RELAY_PORT" 2>/dev/null && echo "  relay listening on 127.0.0.1:$RELAY_PORT" || warn "  relay not listening yet — see $LOGDIR/relay.log"
else
  launchctl bootout "gui/$(id -u)" "$AGENTS/$(label_relay).plist" 2>/dev/null; rm -f "$AGENTS/$(label_relay).plist"
fi

# retire agents for cameras that no longer have a file
for p in "$AGENTS/$LABEL_BASE".*.plist; do
  [ -f "$p" ] || continue
  cam="$(basename "$p" .plist)"; cam="${cam#$LABEL_BASE.}"; cam="${cam%.proxy}"; cam="${cam%.sidecar}"
  [ "$cam" = relay ] && continue
  echo "$CAMS" | grep -qx "$cam" && continue
  launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null; rm -f "$p"; echo "  removed stale agent $(basename "$p")"
done

for cam in $CAMS; do
  load_camera "$cam"
  check_camera || { warn "  skipping $cam — fix its config"; continue; }
  write_agent "$(label_proxy "$cam")" "$RUNTIME/run-proxy.sh" "$cam" "$cam-proxy"
  if [ "${CAM_TYPE:-rtsp}" = "reolink" ] || [ "${CAM_TYPE:-rtsp}" = "onvif" ]; then
    write_agent "$(label_sidecar "$cam")" "$RUNTIME/run-sidecar.sh" "$cam" "$cam-sidecar"
  else
    launchctl bootout "gui/$(id -u)" "$AGENTS/$(label_sidecar "$cam").plist" 2>/dev/null; rm -f "$AGENTS/$(label_sidecar "$cam").plist"
  fi
done

sleep 4
say "status"
l="$(label_relay)"; [ -f "$AGENTS/$l.plist" ] && { agent_loaded "$l" && echo "  relay    running (pid $(agent_pid "$l"))" || warn "  relay    NOT loaded"; }
for cam in $CAMS; do
  l="$(label_proxy "$cam")"
  if agent_loaded "$l"; then echo "  $cam  proxy running (pid $(agent_pid "$l"))"; else warn "  $cam  proxy NOT loaded"; fi
  l="$(label_sidecar "$cam")"
  agent_loaded "$l" && echo "  $cam  sidecar running (pid $(agent_pid "$l"))"
done
say "Done. Logs.command follows the logs; Stop.command / Start.command control every camera."
echo "Auto-login reminder: System Settings > Users & Groups > Automatic login = your account."
pause
