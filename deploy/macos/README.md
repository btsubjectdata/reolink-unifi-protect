# reolink-unifi-protect on a Mac (macOS deploy kit)

Puts non-Ubiquiti RTSP cameras into UniFi Protect as first-class cameras — one proxy
process per camera — and carries the camera's own person/vehicle/animal detections into
Protect as smart detections, with no AI Port:
- **ONVIF cameras** (TP-Link Tapo and most cameras with on-board AI): `onvif_sidecar.py`
  subscribes to the camera's ONVIF events. Event-level detections, no moving boxes.
- **Reolink**: the upstream Baichuan sidecar, with moving bounding boxes and native H.265.

Developed against two TP-Link Tapo C720s (H.264, ONVIF events) on an always-on Mac mini and
a UDM-SE running Protect 7.3. It runs this fork of
[woutersteegers/reolink-unifi-protect](https://github.com/woutersteegers/reolink-unifi-protect)
natively on macOS (no Docker). Compared with upstream, the source in this fork: uses the Mac's
media engine (VideoToolbox) for the HEVC transcode instead of the Intel iGPU the Docker setup
assumes, can write a snapshot JPEG from a live stream's ffmpeg, and speaks the camera protocol
the way **Protect 7.x** requires (see *Protect 7 and the Device Service* below). Smart
detections (person / vehicle / animal) arrive in Protect without an AI Port.

Everything here is double-click `.command` scripts; no Terminal needed after the first run.

## Where things live

| Path | What | Synced? |
|---|---|---|
| this folder (e.g. `~/Documents/reolink-unifi-protect`) | scripts + docs = `deploy/macos` of the repo | iCloud if you put it in Documents (text only) |
| `~/reolink-unifi-protect/` | `src/` (git checkout), `venv/`, sidecar `node_modules`, `relay.yml` (generated, has camera passwords), `snapshots/` | no |
| `~/Library/Application Support/reolink-unifi-protect/` | `.env` (NVR + Protect user), `cameras/<name>.env` (one per camera), `client.pem` | no |
| `~/Library/Logs/reolink-unifi-protect/` | `relay.log`, `<camera>-proxy.log`, `<camera>-sidecar.log`, `install.log` | no |

Secrets never sit in the synced folder. Deleting `~/reolink-unifi-protect` and re-running
`Install.command` rebuilds everything from the two folders that remain.

## The scripts (double-click in Finder)

| Script | Does |
|---|---|
| `Install.command` | Homebrew + python 3.12 / node / ffmpeg@6 / mediamtx, clone, patch, venv, npm, cert, `.env`, keeps the Mac awake. Re-run any time. |
| `EditConfig.command` | Opens `.env` and every `cameras/<name>.env` in TextEdit. |
| `Probe.command` / `ProbeApply.command` | For every camera: checks ports, reads the real codec/resolution/fps/audio, says what to change (Apply writes it). |
| `OnvifProbe.command` | Records 90 s of raw ONVIF events per camera into `logs/` — walk past the cameras while it runs. |
| `ApplyConfig.command` | Installs `config-staging/` into the live config, keeping passwords already entered. |
| `DumpLogs.command` | Copies the last 400 lines of every service log (credentials masked) into `logs/`. |
| `Test.command` | Runs ONE camera's proxy in a Terminal window so you can watch adoption. Ctrl-C to stop. |
| `InstallService.command` | Installs the RTSP relay agent plus one proxy (+ sidecar) agent per camera (start at login, restart on crash). Re-run after adding a camera. |
| `Start.command` / `Stop.command` / `Status.command` / `Logs.command` | Day-to-day control. |
| `Update.command` | Stop → pull upstream → re-patch → reinstall → restart. |

`run-relay.sh` (mediamtx, one for all cameras), `run-proxy.sh <camera>` and
`run-sidecar.sh <camera>` are what the services actually execute
(`CAM_TYPE` in the camera file picks rtsp / onvif / reolink);
`lib.sh` holds the shared paths. `cameras/example-*.env` are the templates for a camera file.
The code changes to upstream are in this fork's source (`unifi/`), summarised here because
each one was a hard-won lesson:

| Change | Why |
|---|---|
| `--transcode-backend videotoolbox` | HEVC sub-stream transcode on the Mac's media engine. |
| `--snapshot-tee PATH` | Snapshot JPEG written by a live stream's ffmpeg: no extra RTSP session (Tapo allows two). |
| `timeStamp`/`statusCode` on every message | **Without these Protect 7 drops all smart detections.** |
| Smart-detect payload in Protect 7's exact shape | `zonesStatus.level`, full descriptor field set, `null` not `{}`. |
| JSON as websocket text frames | Like a real camera. |
| `--adopted` | Connect like an adopted camera, without fetching an adoption token on every start (`CONNECT_WITH_TOKEN=0`). |
| MAC normalised to 12 hex digits | Protect 7's Device Service compares the `camera-mac` header literally. |

## Adding a camera

Copy `cameras/example-tapo.env` (or `example-reolink.env`) to
`~/Library/Application Support/reolink-unifi-protect/cameras/<name>.env`, fill it in with a
unique `CAM_MAC` (and, for Reolink, a unique `AI_SINK_PORT`), run `Probe.command`, then
`InstallService.command`. Removing the file and re-running `InstallService.command` retires it.

## First-time setup

Full walkthrough with the Protect-side clicks is in **SETUP.md**. The short version:

1. `Install.command`
2. `EditConfig.command` — NVR IP + local Protect user in `.env`; IP, Camera Account and name in each `cameras/<name>.env`
3. `Probe.command` — change any HI_*/LO_* numbers it flags
4. `Test.command` — adopt the camera when it appears in Protect, turn on enhanced encoding
5. `InstallService.command` — hand it to launchd; turn on automatic login for the account

## Things that bite

- **`CAM_MAC` is 12 bare hex digits** (`AABBCC000001`), never colon-separated. Protect 7's
  Device Service keys cameras on the literal string, and the proxy's hello builds `hwaddr`
  by slicing two characters at a time.
- **Protect caches model/codec/resolution at adoption.** Any change to `HI_*`, `LO_*`,
  `MODEL`/`SYSID`, or `CAM_MAC` means: remove the camera in Protect, then restart the proxy.
- **Clock.** Protect silently drops frames if the host clock drifts more than ~1 s. macOS
  NTP is on by default; `Status.command` won't tell you about drift, `sntp time.apple.com` will.
- **Login.** launchd *user* agents only run while the account is logged in. Automatic login
  (System Settings → Users & Groups) is what makes a reboot come back up unattended.
- **Tapo cameras need a Camera Account** (Tapo app → camera → Settings → Advanced Settings →
  Camera Account); it is used for RTSP and ONVIF. They send PCM audio, so the default
  `FFMPEG_ARGS` transcodes audio to AAC.
- **Tapo cameras allow only two RTSP sessions — and Protect wants three streams.** A "G5 Pro"
  serves video1 (high), video2 (medium, used by live view in the app) and video3 (low); the proxy
  runs one ffmpeg per stream. Pulled straight from the camera that is three sessions, the third
  fails, and Protect's stream-recovery loop hangs up and restarts streams every ~15 s (choppy
  live view, `Timed out waiting for <MAC>_2 to open` in Protect's `video.recording.log`). So the
  kit runs **mediamtx** as a local relay: it pulls `stream1` + `stream2` from each camera once and
  the proxy reads `rtsp://127.0.0.1:8554/<camera>-hi|-lo` as often as Protect likes (`RELAY=1`,
  the default). Snapshots come from the low stream's ffmpeg (`--snapshot-tee`), so the camera
  always sees exactly two sessions. Anything *else* pulling RTSP — Protect's own 3rd-party
  camera entry, the Tapo app's live view, Home Assistant, `Probe.command` while the relay runs —
  still pushes it over the limit ("400 Bad Request", "Operation not permitted"). Turn off
  Protect → Settings → General → Advanced → *Discover 3rd-Party Cameras* and remove any native
  C720 entries; `Stop.command` before `Probe.command`.
- **Tapo keeps a tiny table of ONVIF subscriptions.** A crash loop fills it and new ones get
  `InvalidArgVal` for up to 10 minutes. The sidecar unsubscribes on exit and backs off.
- **Never click "Click to Update"** on a bridged camera: Protect is offering UniFi firmware to a
  Mac. `FW_VERSION` in the camera file should match the current G5 Pro release to hide it.
- **Reolink WiFi cameras cap concurrent RTSP sessions.** The proxy opens two plus snapshots
  over HTTPS. Don't leave the Reolink app streaming on your phone while debugging.
- **The sidecar needs port 9000 (Baichuan) on the camera.** Some firmware exposes it only
  when "Reolink app" access is enabled. Without it you still get detections, just from the
  slower HTTPS poller and without moving boxes.
- **Protect updates can change the ingest protocol.** If an NVR upgrade breaks live view,
  check the upstream repo's issues before changing anything here.

## Event thumbnails and clip timing (ONVIF cameras)

A Tapo's ONVIF events say *what* was seen, not *where*, and they reach the Mac a few seconds
after the camera saw it. Three things in `run-proxy.sh` / `run-sidecar.sh` deal with that; all
are overridable per camera in `cameras/<name>.env`:

| Setting (default) | What it does |
|---|---|
| `THUMBNAIL_CROP=motion`, `THUMBNAIL_DELAY=5` | For `THUMBNAIL_DELAY` seconds after the event fires the proxy samples the snapshot every 0.5 s, compares each to the frame at detection time (192×108 grey, >18 levels = changed), keeps the frame that changed most and crops a square around the changed area (never tighter than half the frame height). The result is the zoomed thumbnail Protect shows on the event card. `frame` = whole frame letterboxed; `object` = crop around the reported box (Reolink). |
| `EVENT_LEAD=5` | The event is reported as having started this many seconds *before* the push arrived, so the clip starts with the subject walking in rather than mid-frame. |
| `ONVIF_HOLD=3`, `AI_CLEAR_AFTER=1` | Clip tail. Tapo repeats `IsPeople=true` every 1–4 s and only sometimes sends `false`; the sidecar keeps the class present `ONVIF_HOLD` s past the last `true` (a `false` clears it at once), then the proxy ends the event `AI_CLEAR_AFTER` s after the last box report. Tighter than ~3 s splits one walk into several events. |

Watch it work: `Logs.command`, look for `Motion thumbnail: N px changed, grid box (...)` and
`Object crop ready: person#… WxH@x,y`. `nothing moved (0 px), using centre` means every sampled
frame matched the detection-time frame — the camera fired on something static (or on a subject
already out of shot).

## Audio and Safari live view

- The proxy advertises AAC at **16 kHz** to Protect. Transcode the camera's audio to the same
  rate (`-ar 16000` in `FFMPEG_ARGS`, the example default); at 32 kHz Safari's live view
  flickers "Live view did not load" while Chrome and the apps play fine.
- Some Tapo firmware emits malformed H.264 SEI NAL units (`SEI type 764 truncated` in the
  log). They are harmless metadata; drop them with `-bsf:v filter_units=remove_types=6` in
  `FFMPEG_ARGS` if a browser is picky about that camera.

## Protect 7 and the Device Service

Protect 7.x moved camera handling (port 7442) out of the Node app into a Rust service,
`/usr/bin/ds` ("Device Service"). It parses every camera message into strict structs and
handles smart-detect / analytics events itself; anything it cannot parse is forwarded to the
old Node path untouched, which then logs

    Received EventSmartDetect over avclient which was not expected to be received;
    DS should handle this message

and discards it — no error reaches the camera. Found by diffing a real G4 Doorbell's traffic
against the proxy's with DS's own trace switches (`/usr/share/ds/ds.json` →
`trace.log_websocket_payload`, `log_smartdetect_payload`, `log_level: debug`;
`systemctl restart ds`; logs in `/volume/*/.srv/ds/logs/ds.log`). What differed, in the order
it mattered:

1. **Envelope** — real cameras send `"statusCode": 0` and `"timeStamp": "…+00:00"` on every
   message; DS's `CameraMessage` needs them (`gen_response` in `unifi/cams/base.py`). This was the gate.
2. **Descriptors** — `attributes` must be `null` (an object is parsed as a full attribute
   struct), `coord3d` ints, plus `firstShownTimeMs`/`idleSinceTimeMs`/`boxColor`/`tag`…;
   `zonesStatus` entries need `level`; `linesStatus`/`loiterZonesStatus`/… must be `null` or
   the event is filed as a line-crossing (`_ds_payload_fill` / `build_smart_descriptor`).
3. **MAC** without colons (config), text frames and no adoption token on reconnect
   (`--adopted`) — not gates on 7.3.70 by themselves, but
   they make the proxy indistinguishable from a real camera, which is the safest place to be
   when Ubiquiti tightens things again.

Useful on the UDM (SSH as root): `psql -h 127.0.0.1 -p 5433 -U postgres -d unifi-protect`
holds `cameras`, `events`, `smartDetectRaws` (a real camera's stored payloads);
`grep SmartDetectHandler /volume/*/.srv/ds/logs/ds.log` shows DS handling events per camera id.
