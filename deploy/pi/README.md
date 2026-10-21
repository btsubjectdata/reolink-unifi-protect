# ONVIF cameras (Tapo etc.) → UniFi Protect on a Raspberry Pi 4/5

The macOS kit's job on a Pi: TP-Link Tapo (or any ONVIF camera with on-board person /
vehicle / animal detection) into Protect as a first-class camera with smart detections, no AI
Port. H.264 cameras only — everything is `-c:v copy`, so a Pi 4 runs two 2K cameras at
~25–35 % CPU and ~600 MB RAM. A Pi has no H.265 encoder; for a Reolink with an H.265 main
stream use [`deploy/n100`](../n100) instead.

Same three containers per camera as [`deploy/onvif`](../onvif) (mediamtx relay, proxy, ONVIF
sidecar), plus:

- **one compose, many cameras** — `cameras/<name>.env` per camera, `bridge.sh` runs each as its
  own project with its own ports
- **nothing is written to the SD card** while running: the once-a-second snapshot JPEG and the
  event crops live in RAM (`/dev/shm`), container logs are capped at 10 MB
- a Debian image that builds on arm64 with no toolchain (a few minutes on a Pi 4)
- `import-mac-config.sh` — moves the macOS kit's configuration over, keeping `CAM_MAC` so Protect
  keeps the cameras and their history

## Hardware

Raspberry Pi 4 (2 GB works, 4 GB comfortable) or Pi 5, **wired Ethernet**, a case with a
heatsink or fan, 32 GB A2-class microSD. The OS lives on the SD card; no SSD needed because the
bridge writes almost nothing to disk.

## 1. OS

Raspberry Pi OS **Lite, 64-bit** (Imager: set hostname, user, SSH, locale). Then:

```sh
sudo apt update && sudo apt full-upgrade -y
curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER   # log out / in
sudo apt install -y git
timedatectl    # "NTP service: active" — Protect drops frames past ~1 s of clock drift
git clone https://github.com/btsubjectdata/reolink-unifi-protect.git && cd reolink-unifi-protect/deploy/pi
```

## 2. Cameras

Fresh install: `cp cameras/example-tapo.env cameras/driveway.env` per camera, fill it in
(Tapo: the *Camera Account* from the app, `stream1`/`stream2`, ONVIF port 2020), give each
camera its own `RELAY_PORT` / `AI_SINK_PORT` / `SNAPSHOT_PORT` / `PUSH_PORT`, `chmod 600`.
Generate a client certificate once:

```sh
openssl req -x509 -nodes -newkey rsa:2048 -keyout client.key -out client.crt -days 3650 \
  -subj "/C=US/ST=TX/L=Home/O=bridge/CN=bridge" && cat client.key client.crt > client.pem && chmod 600 client.pem
```

**Moving from the Mac** (keeps the cameras in Protect, no re-adoption):

1. On the Mac, copy `~/Library/Application Support/reolink-unifi-protect/` (its `.env`,
   `cameras/`, `client.pem`) to the Pi, e.g. `scp -r` into `/tmp/mac-config`.
2. `./import-mac-config.sh /tmp/mac-config` → one `cameras/<name>.env` per camera, `ADOPTED=1`
   where the Mac already ran tokenless, ports assigned, the same `client.pem`.
3. **Stop the Mac first** (`Stop.command`) — two bridges with the same MAC fight over the
   camera and the NVR. Then `./bridge.sh up`. Protect sees the "same camera" come back from a
   new IP; live view and events resume, history intact. Delete the config copy in `/tmp`.
4. On the Mac, when happy: `Status.command` should show nothing running; remove the launchd
   agents with the kit's `Stop.command` + delete `~/Library/LaunchAgents/io.github.reolink-unifi-protect.*`.

## 3. Run

```sh
./bridge.sh up            # build (first time: ~5 min on a Pi 4) and start every camera
./bridge.sh logs driveway # one camera's proxy + sidecar log
./bridge.sh status        # all containers
./bridge.sh down          # stop everything
```

Fresh cameras appear in Protect → Devices for adoption; adopt, enable enhanced encoding is
**not** needed (H.264), then set `ADOPTED=1` in that camera's file and `./bridge.sh up` again.
Containers restart on crash and come back after a reboot on their own.

Protect side, once: Settings → General → Advanced → turn off *Discover 3rd-Party Cameras*;
never click *Click to Update* on a bridged camera.

## Tuning

Everything the macOS kit has, per camera file: `FFMPEG_ARGS` (16 kHz audio for Safari;
`-bsf:v filter_units=remove_types=6` strips a Tapo's malformed SEI units), `THUMBNAIL_CROP` /
`THUMBNAIL_DELAY` (motion-picked thumbnails), `EVENT_LEAD` (clip starts before the walk-in),
`ONVIF_HOLD` / `AI_CLEAR_AFTER` (clip tail). See
[`deploy/macos/README.md`](../macos/README.md#event-thumbnails-and-clip-timing-onvif-cameras).

If the Pi runs hot: lowering the cameras' sub stream to 15 fps and 1 Mbps helps (it is the only
stream that is decoded, for the once-a-second snapshot); the main stream is never decoded.

## After a Protect update

Same as the other kits: if the camera flaps or Protect offers it an update, set `FW_VERSION` to
the current G5 Pro release from
`https://fw-update.ui.com/api/firmware-latest?filter=eq~~platform~~sav837gw&filter=eq~~product~~uvc`;
if detections stop, `grep -i "not expected\|Failed to parse" /volume/*/.srv/ds/logs/ds.log` on
the NVR names the field that changed.

*Prepared ahead of hardware: the compose and flag assembly are verified against the proxy;
the arm64 image build and first run are pending.*
