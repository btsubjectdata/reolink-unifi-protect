# SETUP — step by step

Do this on the Mac that will run the bridge (an always-on Mac mini is ideal), logged in as the
account that will stay logged in. Start by copying `deploy/macos/` from the repo to a folder of
your own, e.g. `~/Documents/reolink-unifi-protect` — download the repo as a ZIP from GitHub, or
`git clone` it; the scripts clone the code they need themselves.

## 0. Before you start

- Camera and UDM/NVR reachable from the mini (same VLAN is simplest; otherwise allow the
  mini → camera on 554/443/9000 and mini → NVR on 443/7442/7443).
- Tapo cameras: in the Tapo app → camera → Settings → Advanced Settings → **Camera Account**,
  create a username/password. That (not your TP-Link login) is what RTSP uses.
  Reolink cameras: Settings → Network → Advanced → Port settings → **RTSP on**, HTTPS on.
- Give each camera a DHCP reservation in UniFi (Client → Settings → Fixed IP).
- In Protect (web → Settings → Admins & Users): add a **local** user, e.g. `protect-bridge`, with the
  Protect **Administrator** role (needed for `cameras/manage-payload`, which issues adoption
  tokens). Remote access / UI account not required. Using a user means the proxy fetches a
  fresh token on every restart, so you never paste a 60-minute token.

## 1. Install

Double-click `Install.command`. It asks for your password twice (Homebrew, `pmset`). Takes a
few minutes the first time (ffmpeg is a large brew). It ends with "Installed."

If Homebrew was not on the Mac yet, open a **new** Terminal after the install so `brew` is on
the PATH, then run `Install.command` once more.

## 2. Configure

`EditConfig.command` opens `.env` (NVR + Protect user) and one window per camera file:

```
# .env
NVR_IP=192.168.1.1
NVR_USER=protect-bridge
NVR_PASS=...

# cameras/driveway.env
CAM_IP=192.168.1.50
CAM_USER=<Tapo camera account>
CAM_PASS=...
CAM_NAME="Driveway"
CAM_MAC=AABBCC001116          # unique per camera, 12 hex digits, NO colons (Protect 7.x DS ignores colon form)
```

Leave the rest alone for the first pass. Save each window.

`RELAY=1` (default) keeps the relay in front of the camera — leave it unless a camera has no
session limit and you want one fewer moving part.

## 3. Probe

`Probe.command`. Every port line should say OK. For each camera it prints what the main and
sub streams actually carry and flags any `HI_*` / `LO_*` line in that camera's file that
disagrees. Fix those (`EditConfig.command`) **before** adopting; Protect caches them.

Codec decision, from what Probe says:

| main | sub | set |
|---|---|---|
| h265 | h264 | keep defaults (`LO_TRANSCODE=1`): full H.265, VideoToolbox re-encodes the sub stream |
| h265 | h265 | `LO_TRANSCODE=0` — pure passthrough, no transcode at all |
| h264 | h264 | `HI_CODEC=h264 LO_CODEC=h264 LO_TRANSCODE=0`; skip the enhanced-encoding step below |

## 4. Test and adopt

`Test.command` (it asks which camera if there is more than one). Within ~10 s the log should
show the proxy connecting to the NVR. Then:

1. Protect → Devices. The camera appears as an unadopted **UVC G5 Pro** with the name you set.
   Click it → **Adopt**. Live view should start within a few seconds.
2. H.265 cameras only (`HI_CODEC=h265`): camera → Settings → **Enhanced encoding** → on.
   Leave it OFF for H.264 cameras such as the Tapo C720.
3. Settings → Smart Detections → add a zone, enable Person / Vehicle / Animal, walk in front
   of the camera. The proxy log prints `AI boxes: person@90% — starting smart event` and Protect
   logs a Person detection. ONVIF cameras give a fixed box; Reolink gives a moving one.
   (`CAM_TYPE=rtsp` cameras get no detections at all.)

Repeat `Test.command` for the second camera, or go straight to step 5 — the services run every
camera.

If live view spins forever, see Troubleshooting. Ctrl-C in the Terminal when done.

## 5. Make it permanent

`InstallService.command`. Then System Settings → Users & Groups → **Automatic login** → your
account, so a power-blip reboot comes back without a keyboard.

`Status.command` any time; `Logs.command` to tail.

Once a camera has been adopted, set `CONNECT_WITH_TOKEN=0` in its camera file (or in
`config-staging/cameras/<name>.env` + `ApplyConfig.command`) and re-run `InstallService.command`.
The proxy then reconnects the way a real adopted camera does instead of re-adopting on every
start.

## Troubleshooting

**Streams fine, motion events fine, but no Person/Vehicle/Animal detections (Protect 7.x)**
The proxy log shows `Triggering motion start … for person` but Protect's timeline only ever
shows plain motion, or nothing. Protect 7 hands smart detections to its Device Service, which
only accepts messages in the exact shape a UniFi camera sends; see *Protect 7 and the Device
Service* in README.md. Check `Install.command` reported "VideoToolbox backend present" (i.e. it
cloned this fork, not upstream), and on the UDM (`ssh root@<nvr>`) that
`grep -c "not expected" /volume/*/.srv/unifi-protect/logs/cameras.avclient.log` stops growing
while `grep "Event started" /volume/*/.srv/ds/logs/ds.log | grep <CAM_MAC>` does.

**Live view choppy / Protect keeps restarting the streams**
`Status.command`: the relay must be UP and listening; each camera should show 2–3 ffmpeg
workers that stay put. If `relay.log` says `no route to host` for the cameras, macOS is asking
for Local Network permission for mediamtx — click Allow on the prompt (System Settings →
Privacy & Security → Local Network if you missed it). If Protect's `video.recording.log` shows
`Timed out waiting for <MAC>_2 to open` every 30 s, something else holds a camera RTSP session
(see README, *Tapo cameras allow only two RTSP sessions*).

**Camera never appears in Protect**
`Logs.command`. "Could not automatically fetch token": wrong `NVR_USER/NVR_PASS`, or the user
isn't a local Protect admin. Connection refused on 7442: NVR_IP wrong or firewall.

**Appears but adoption fails / keeps re-adopting**
`client.pem` was regenerated after a previous adoption, or `CAM_MAC` changed. Remove the
camera in Protect and adopt again.

**Live view spins, snapshot works**
Protect is getting a codec it isn't expecting. Either enhanced encoding is off while
`HI_CODEC=h265` (turn it on), or on while a channel is H.264 (`LO_TRANSCODE=1` not taking —
check `ffmpeg -encoders | grep videotoolbox` and that the proxy log shows
`hevc_videotoolbox` in its ffmpeg line). After any `.env` codec change: remove camera in
Protect → `Stop` → `Start` → re-adopt.

**ffmpeg for video2/video3 exits immediately**
The VideoToolbox decode or encode failed to open. Set `EXTRA_ARGS=-v` in `.env`, restart,
copy the full ffmpeg command out of the log, run it by hand in Terminal and read the error.
To keep the camera working meanwhile: `LO_TRANSCODE=0`, `LO_CODEC=h264`, `HI_CODEC=h264`,
enhanced encoding off, remove + re-adopt. (The fallback costs the 5K H.265 main stream, not
the smart detections.)

**Detections arrive but boxes don't move / "animal" for people**
Firmware differences in the Baichuan TLVs. The sidecar logs `copies [...]` lines once per
second; compare to what the Reolink app shows and adjust `AI_CONFIDENCE_OVERRIDES` (e.g.
`animal=0.8`). Upstream README's protocol notes explain the type1/type2 reversal.

**Frames dropping, "clock drift" in the log**
`sntp -sS time.apple.com` (needs sudo). Check System Settings → General → Date & Time is set
automatically.

**After a macOS or Protect update**
`Update.command` first (pulls the latest fork code, reinstalls, restarts). Homebrew may have moved
ffmpeg; `Install.command` re-checks it.

## Removing it

```
Stop.command
rm ~/Library/LaunchAgents/io.github.reolink-unifi-protect.*.plist
rm -rf ~/reolink-unifi-protect
rm -rf ~/Library/Application\ Support/reolink-unifi-protect   # passwords + cert
```

then remove the camera in Protect. Homebrew packages stay (other things may use them).
