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
| `RemoteShell.command` | Optional helper: runs scripts dropped into `agent/queue/` and writes output to `agent/out/` (used for remote support). Close the window to stop. |

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

