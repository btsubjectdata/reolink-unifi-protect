# Reolink → UniFi Protect on a small Intel box (N95 / N100 / N150 / Core-U mini PC)

The full-featured path for a Reolink camera — verified upstream on a **Reolink Elite
Floodlight WiFi** (5120×1552 H.265, 180° dual-lens) with Protect 7.3.70:

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
Core i3/i5/Core-U. 8 GB RAM and a 128 GB SSD are plenty; wired Ethernet. Avoid AMD for this
recipe (different encoder path, untested). Expect ~10–15 W at the wall.

## 1. Operating system

Ubuntu Server 24.04 LTS (or Debian 12), minimal install, wired, static IP or DHCP
reservation on the router. Then:

```sh
sudo apt update && sudo apt install -y docker.io docker-compose-v2 git ffmpeg vainfo intel-media-va-driver-non-free
sudo usermod -aG docker,video,render $USER     # log out and back in
vainfo | grep -i hevc                          # must list HEVC *Enc* entry points
timedatectl                                    # NTP must be active: Protect drops frames past ~1 s of drift
```

## 2. The camera (Reolink app or web UI)

- **Network → Advanced → Port**: enable **RTSP**, **ONVIF**, **HTTPS** (HTTP optional).
- **User Management**: add a dedicated admin user for the bridge (the AI / push / spotlight
  API needs admin). Use it, not your own.
- **Stream (Clear)**: leave H.265; 15–20 fps; bitrate 6–8 Mbps for a 5K panoramic.
  **Fluent**: note its resolution (1536×432 or 1920×576) and fps.
- Make sure the camera is **not** adopted directly in Protect (Settings → General → Advanced →
  turn off *Discover 3rd-Party Cameras*, remove any native entry): two owners fight over its
  RTSP sessions.

## 3. Probe (on the box, at the camera's site)

```sh
git clone https://github.com/btsubjectdata/reolink-unifi-protect.git
cd reolink-unifi-protect/deploy/n100
./probe.sh <camera-ip> <camera-user> '<camera-password>'
```

It checks ports 554 / 443 / 9000, reads the real codec, size and fps of both streams, tests
the HTTPS snapshot and AI API, and prints the `HI_*` / `LO_*` lines for `.env`. Protect
**caches these at adoption** — a wrong number means remove the camera in Protect and adopt
again, so get them from the probe, not the spec sheet.

## 4. Configure

```sh
cp .env.example .env && nano .env                  # fill in; chmod 600 .env
openssl req -x509 -nodes -newkey rsa:2048 -keyout client.key -out client.crt -days 3650 \
  -subj "/C=US/ST=TX/L=Home/O=bridge/CN=bridge" && cat client.key client.crt > client.pem
```

`NVR_USER` / `NVR_PASS` is a **local** Protect admin made for the bridge (Protect → Settings →
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
