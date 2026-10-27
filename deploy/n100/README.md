# Reolink → UniFi Protect on a small Intel box (N95 / N100 / N150 / Core-U mini PC)

The full-featured path for a Reolink camera — verified upstream on a **Reolink Elite
Floodlight WiFi** (5120×1552 H.265, 180° dual-lens) with Protect 7.3.70, and updated here
for the camera's 2026 firmware (encrypted HTTP API, see §2):

- the camera's **native H.265 main stream passed through untouched** (no quality loss)
- the H.264 sub stream transcoded to H.265 on the **Intel iGPU (Quick Sync)** — Protect wants
  every channel in HEVC once enhanced encoding is on; this is why it can't be a Raspberry Pi
- **Person / Vehicle / Animal with moving bounding boxes** from the camera's own AI over its
  Baichuan channel (port 9000), push events (no polling), HTTPS snapshots, per-object event
  thumbnails
- floodlight / spotlight and camera reboot from Protect's own controls
- no AI Port, no cloud, nothing leaves the LAN

One container, `docker compose up -d`, restarts itself, survives reboots.

## Hardware

Any mini PC with an **Intel** CPU that has Quick Sync HEVC encode: N95, N100, N150, or a
Core i3/i5/Core-U (the hardware path — Quick Sync decode, HEVC encode, UniFi FLV framing — is
verified on a Core 3 100U). 8 GB RAM and a 128 GB SSD are plenty; wired Ethernet. Avoid AMD for this
recipe (different encoder path, untested). Expect ~10–15 W at the wall.

## 1. Operating system

**Ubuntu Server 26.04 LTS** (plain "Ubuntu Server", not "minimized"), wired, DHCP reservation
on the router. In the installer: use the entire disk, tick *Install OpenSSH server*, select no
snaps (in particular not the Docker snap — it cannot see the iGPU properly).

Two things the installer gets wrong, fix them first:

```sh
# 1. it only allocates 100 GB of an LVM disk; give the system all of it
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
# 2. if you installed over WiFi, the wired port gets no DHCP at all; check:
cat /etc/netplan/*.yaml       # enp...: must have "dhcp4: true" - add it, then: sudo netplan apply
```

Then the software:

```sh
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git ffmpeg vainfo intel-media-va-driver-non-free libvpl2 libmfx-gen1.2
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker,video,render $USER     # log out and back in
sudo timedatectl set-timezone America/Chicago  # your zone
vainfo | grep -i "HEVCMain.*Enc"               # must list HEVC encode entry points
timedatectl                                    # NTP must be active: Protect drops frames past ~1 s of drift
```

Quick Sync self-test (H.264 in, H.265 out on the iGPU, should finish in ~2 s):

```sh
ffmpeg -nostdin -loglevel error -y -f lavfi -i testsrc2=s=1536x432:r=20 -t 20 -c:v libx264 /tmp/sub.mp4
ffmpeg -nostdin -loglevel error -y -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw \
  -i /tmp/sub.mp4 -vf hwupload=extra_hw_frames=64,format=qsv -c:v hevc_qsv -b:v 1M /tmp/out.mp4 && echo QSV OK
```

`Error creating a MFX session: -9` means the oneVPL GPU runtime is too old for the chip
(Ubuntu 24.04's libmfx-gen 23.x fails on a Core 3 100U); that is why both this host and the
image use 26.04.

## 2. The camera (Reolink app)

- Camera → ⚙ → **More Features → Advanced Network Settings → Server Settings**: switch on
  **RTSP**, **ONVIF** and **HTTPS** (older apps: Network → Advanced → Port). Leave HTTP and
  RTMP off.
- A dedicated admin user for the bridge (the AI / push / spotlight API needs admin). Current
  Reolink apps hide *User Management*; create it over the camera's own API instead, from the
  box, once the image is built (step 4):

  ```sh
  REOLINK_PASS='<camera admin password>' docker compose run --rm --entrypoint python \
    -e REOLINK_PASS proxy -m unifi.reolink_tool --host <camera-ip> --user admin add-user bridge
  ```

  It prints the new user's generated password once — that is `CAM_PASS`. The admin
  password is used for this one call and stored nowhere.
- **Stream (Clear)**: leave H.265; 20–25 fps; bitrate 6–8 Mbps for a 5K panoramic.
  **Fluent**: note its resolution (1536×432 or 1920×576) and fps — or read both from
  `... reolink_tool --host <camera-ip> --user bridge info`.

### Firmware from 2025 on: the encrypted API

Cameras on recent firmware (seen: Elite Floodlight WiFi **v3.2.0.6011**, March 2026) refuse
the classic HTTP API: a plaintext `Login` answers `login deny` (-503) and the
`cmd=Snap&user=&password=` snapshot URL answers `login failed`, even with the right
password — only RTSP and ONVIF still accept it directly. They speak the protocol of their
own web page instead: an HTTP-digest login (`WWW-Authenticate` challenge, MD5 response),
then every request body AES-128-CFB encrypted with a key derived from the nonce and the
password, and a per-request check number in the query string. `unifi/reolink_api.py`
implements it (and falls back to the plain login on older cameras), the spotlight, image
settings, reboot and `reolink_tool` use it, and snapshots come through it with
`--snapshot-url reolink://main` (what this compose uses). The Baichuan push channel
(port 9000) that delivers the AI events is a separate protocol and was never affected.

Symptoms of hitting this with older code: snapshots/thumbnails missing, spotlight never
switching, `login deny` in the log, while live view works.
- Make sure the camera is **not** adopted directly in Protect (Settings → General → Advanced →
  turn off *Discover 3rd-Party Cameras*, remove any native entry): two owners fight over its
  RTSP sessions.

## 3. Probe (on the box, at the camera's site)

```sh
git clone https://github.com/btsubjectdata/reolink-unifi-protect.git
cd reolink-unifi-protect/deploy/n100
./probe.sh <camera-ip> <camera-user> '<camera-password>'
```

It checks ports 554 / 443 / 9000, reads the real codec, size and fps of both streams over
RTSP and prints the `HI_*` / `LO_*` lines for `.env` (its HTTPS snapshot / API checks only
pass on older firmware — see above; use `reolink_tool info` on new ones). Protect **caches
these at adoption** — a wrong number means remove the camera in Protect and adopt again, so
get them from the probe, not the spec sheet. The floodlight on v3.2.0.6011 runs
5120×1552 @ 25 fps and 1920×576 @ 25 fps; earlier firmware reported 20 fps and 1536×432.

## 4. Configure

```sh
cp .env.example .env && nano .env                  # fill in; chmod 600 .env
openssl req -x509 -nodes -newkey rsa:2048 -keyout client.key -out client.crt -days 3650 \
  -subj "/CN=unifi-cam-proxy" && cat client.key client.crt > client.pem
```

`VIDEO_GID` / `RENDER_GID` are the host's group ids from `getent group video render` (the
container joins them to use the iGPU). `NVR_USER` / `NVR_PASS` is a **local** Protect admin made for the bridge (Protect → Settings →
Admins & Users → Add → local, Administrator). `CAM_MAC` is any unique 12-hex-digit value.
`FW_VERSION` must match the current UVC G5 Pro release — see *After a Protect update*.

## 5. Adopt

```sh
docker compose up -d --build && docker compose logs -f
```

The proxy logs in, fetches an adoption token, and the camera appears in Protect → Devices as
a "G5 Pro" waiting for adoption. Adopt it, then in its settings turn on **enhanced encoding**
(H.265). Watch the log: `Spawning ffmpeg for video1/2/3`, then detections as
`Triggering motion start … for person`. Walk in front of it: event card with a box, clip,
thumbnail.

Then set `ADOPTED=1` in `.env` and `docker compose up -d` — from now on it reconnects like
an already-adopted camera and never needs the Protect login again.

## 6. Day to day

| | |
|---|---|
| logs | `docker compose logs -f --tail 200` |
| restart | `docker compose restart` |
| update code | `git pull && docker compose up -d --build` |
| status in Protect | the camera shows the host's IP; "Click to Update" must **never** be clicked (it would push UniFi firmware at a Linux box) |

## Clock overlay jumping back a second / jittery motion

Seen on the Elite Floodlight over WiFi: the camera's frame timestamps arrive uneven and
occasionally go backwards, so Protect shows a frame out of order. `FFMPEG_ARGS` in
`.env.example` re-times the passthrough stream with ffmpeg's `setts` filter (no
re-encode, no CPU cost). Check a camera with:

```sh
ffprobe -v error -rtsp_transport tcp -select_streams v:0 -read_intervals %+6 \
  -show_entries packet=dts -of csv=p=0 "rtsp://user:pass@<cam>:554/h264Preview_01_main" \
  | awk 'NR>1 && $1<=p {b++} {p=$1} END {print b+0, "backward/repeated timestamps"}'
```

## After a Protect update

1. Does the camera still show live view and events? If yes, done.
2. If Protect offers an *update* for the camera or it flaps every ~11 s: the catalog's G5 Pro
   version moved. Read the current one from
   `https://fw-update.ui.com/api/firmware-latest?filter=eq~~platform~~sav837gw&filter=eq~~product~~uvc`
   and put it in `FW_VERSION`, then `docker compose up -d`.
3. If live view works but smart detections stopped: Protect changed the camera protocol again.
   On the NVR, `grep -i "not expected\|Failed to parse" /volume/*/.srv/ds/logs/ds.log` says
   which field. Open an issue with that line; the message shape is pinned by tests in this
   repo so the fix is usually small.

## Why it isn't a Raspberry Pi

A Pi 4 / Pi 5 has no HEVC *encoder*. The Elite Floodlight's main stream is H.265-only
(there is no H.264 switch above 4K), which turns on enhanced encoding in Protect, which
requires the sub stream in HEVC too. A Pi could only carry the camera's 2560×720 H.264
"balanced" stream (HTTP-FLV only) — a real downgrade from 5K. Any Intel box with Quick Sync
does the whole thing at a few percent load.

## Credits

The Reolink / floodlight path is [jikdoc/reolink-unifi-protect](https://github.com/jikdoc/reolink-unifi-protect)
(andy83-projects), merged into this tree with the macOS / Tapo / ONVIF work and the
thumbnail / clip-timing options. Not affiliated with Ubiquiti or Reolink; the proxy emulates
a UniFi camera toward your own NVR and Protect updates can change the protocol at any time.
