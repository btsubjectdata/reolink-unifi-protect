# Step-by-step: Tapo / ONVIF cameras into UniFi Protect on a Raspberry Pi

This is the long version of [README.md](README.md), written so that you can follow it
without knowing Docker or Linux. Budget about an hour the first time. Every command is meant
to be copied and pasted as-is; where you must change something it says so.

**What you end up with:** your Tapo (or other ONVIF) camera shows up in UniFi Protect like a
UniFi camera — live view, timeline, recordings on the NVR, and Person / Vehicle / Animal
smart detections from the camera's own AI. No AI Port, no cloud, no monthly fee.

---

## 0. What you need

| | |
|---|---|
| Raspberry Pi | Pi 4 (2 GB works, 4 GB better) or Pi 5, with its official power supply |
| microSD card | 32 GB, "A2" class (SanDisk Extreme / Samsung EVO Select or similar) |
| Case | one with a heatsink or small fan; the Pi runs warm 24/7 |
| **Ethernet cable** to a switch | **not optional.** Over WiFi the camera streams drop packets and Protect keeps restarting them. |
| A computer to flash the card from | Windows, Mac or Linux |
| UniFi Protect | on a UDM / UDM-SE / UDM-Pro / UNVR / Cloud Key. Tested on 7.3.70; earlier 5.x–6.x also work |
| Camera | TP-Link Tapo (C2xx / C3xx / C5xx / C7xx), or any ONVIF camera with its own person/vehicle/animal detection. H.264 video (every Tapo). |

---

## 1. Prepare the camera (Tapo app, 5 minutes)

1. Open the Tapo app → your camera → **Settings (gear)** → **Advanced Settings** → **Camera
   Account**. Turn it on and set a **username and password**. Write them down — this is what
   the bridge logs in with. (Any ONVIF-capable brand: create a user with admin rights in the
   camera's own app or web page, and enable RTSP + ONVIF.)
2. Give the camera a **fixed IP** in UniFi Network: Network app → Clients → the camera →
   Settings → **Fixed IP Address** → Apply. Write the IP down.
3. In the Tapo app, **Settings → Video** set the main stream to the highest quality it offers
   and leave the sub stream as is. Note the resolution the app shows (e.g. 2560×1440 for a C720).
4. In **UniFi Protect** → Settings → System → Advanced: make sure **"Discover 3rd-Party
   Cameras" is OFF**, and if Protect already lists the Tapo as a third-party/ONVIF camera,
   **remove** it. (Protect's own ONVIF entry and the bridge would fight over the camera's two
   allowed RTSP sessions.)

---

## 2. Flash and boot the Pi (15 minutes)

1. Download **Raspberry Pi Imager** from raspberrypi.com/software and run it.
2. Choose device: your Pi model. Choose OS: **Raspberry Pi OS (other) → Raspberry Pi OS Lite
   (64-bit)**. (The full desktop version also works; it just uses more memory.)
3. Choose storage: the microSD card. Click **Next** → **Edit settings**:
   - General: hostname `camerabridge`, username `pi` and a password you choose, set your
     time zone, keyboard.
   - Services: **Enable SSH**, "Use password authentication".
   - Save → Yes → Yes. Wait for "write successful".
4. Put the card in the Pi, plug in **Ethernet**, then power. Wait two minutes.
5. In UniFi Network → Clients you will see `camerabridge`. Note its IP (say 192.168.1.70) and
   give it a **Fixed IP** too (Settings → Fixed IP Address → Apply).

---

## 3. Log in to the Pi

From a Mac or Linux terminal, or Windows PowerShell:

```
ssh pi@192.168.1.70
```

(use your Pi's IP). Say `yes` to the fingerprint question, enter the password you chose.
Everything below is typed at the `pi@camerabridge:~ $` prompt.

---

## 4. Install the software (10 minutes, mostly waiting)

Paste these one block at a time.

```sh
sudo apt update && sudo apt full-upgrade -y
```

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker pi
sudo apt install -y git
```

Now **log out and back in** so the `docker` group takes effect:

```sh
exit
```

…then `ssh pi@192.168.1.70` again. Check it worked:

```sh
docker run --rm hello-world
timedatectl
```

The first prints "Hello from Docker!". The second must say `NTP service: active` and
`System clock synchronized: yes` — Protect drops video if the clock is off by more than a second.

Get the code:

```sh
git clone https://github.com/btsubjectdata/reolink-unifi-protect.git
cd ~/reolink-unifi-protect/deploy/pi
```

---

## 5. Make the certificate (once)

The bridge presents a client certificate to Protect, like a real camera does. Any
self-signed one works:

```sh
openssl req -x509 -nodes -newkey rsa:2048 -keyout client.key -out client.crt -days 3650 -subj "/CN=unifi-cam-proxy"
cat client.key client.crt > client.pem && chmod 600 client.pem && rm client.key client.crt
```

---

## 6. Create a Protect user for the bridge (once)

In **UniFi Protect** (web) → Settings → **Admins & Users** → **Add Admin** →
*Restrict to local access only*, username `protect-bridge`, a strong password, role
**Administrator** (adoption needs it). Write it down.

---

## 7. Describe your camera

One file per camera. Start from the example:

```sh
cp cameras/example-tapo.env cameras/driveway.env
chmod 600 cameras/driveway.env
nano cameras/driveway.env
```

Change these lines (arrow keys to move, Ctrl+O then Enter to save, Ctrl+X to exit):

| Line | Set to |
|---|---|
| `NVR_IP=` | your Protect console's IP (the UDM, e.g. `192.168.1.1`) |
| `NVR_USER=` / `NVR_PASS=` | the Protect user from step 6 |
| `CAM_IP=` | the camera's fixed IP from step 1 |
| `CAM_USER=` / `CAM_PASS=` | the Camera Account from step 1 |
| `CAM_NAME=` | what you want Protect to call it (`Driveway`) |
| `CAM_MAC=` | **12 hex digits, unique per camera**, e.g. `AABBCC000001`. Make one up. Never change it later — Protect identifies the camera by it. |
| `HI_WIDTH=` / `HI_HEIGHT=` / `HI_FPS=` | the main stream's real resolution and frame rate (C720: 2560 / 1440 / 15). Wrong numbers = no video; see *Checking the streams* below if unsure |
| `LO_WIDTH=` / `LO_HEIGHT=` / `LO_FPS=` | the sub stream (Tapo: 1280 / 720 / 15) |

Leave everything else alone for now. `ADOPTED=0` is correct for a new camera.

**Checking the streams** (optional but recommended — do it once per camera model):

```sh
sudo apt install -y ffmpeg
ffprobe -v error -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name,width,height,avg_frame_rate -of csv=p=0 "rtsp://USER:PASSWORD@CAMERA-IP:554/stream1"
ffprobe -v error -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name,width,height,avg_frame_rate -of csv=p=0 "rtsp://USER:PASSWORD@CAMERA-IP:554/stream2"
```

(replace the three capitals). It prints e.g. `h264,2560,1440,15/1` — those are your `HI_*`
numbers; the second line your `LO_*` numbers. If the password has `@` or `#` in it, the
bridge handles that, but for this one manual test you must type it URL-encoded (`@` → `%40`,
`#` → `%23`).

**Second camera:** `cp cameras/driveway.env cameras/backyard.env`, edit it, and give it its
own ports — change the four port lines to `RELAY_PORT=8555`, `AI_SINK_PORT=7998`,
`SNAPSHOT_PORT=8998`, `PUSH_PORT=9998` (third camera: 8556 / 7997 / 8997 / 9997, and so on).

---

## 8. Start it

```sh
./bridge.sh up
```

The first run builds two small container images — **3–5 minutes on a Pi 4**, with a lot of
scrolling text. It ends with lines like `Container driveway-proxy Started`. Then:

```sh
./bridge.sh logs driveway
```

(the name is your file's name without `.env`). Within a minute you should see
`Spawning ffmpeg for video1`, `video2`, `video3`. Press Ctrl+C to stop watching (the bridge
keeps running).

---

## 9. Adopt it in Protect

1. Open **UniFi Protect** → **Devices** (or the Unifi app → Protect → Devices). Within a
   minute a new **"UVC G5 Pro"** appears, waiting to be adopted. Its name is your `CAM_NAME`.
2. Click it → **Adopt**. Wait ~30 s. Live view appears.
3. **Do not** click "Click to Update" / "Update firmware" — ever. Protect is offering UniFi
   camera firmware to your Raspberry Pi.
4. Walk in front of the camera. Within ~10 s a Person event with a thumbnail appears on the
   timeline. (Tapo detections are only as good as the camera's own: set up its detection
   zones and sensitivity in the Tapo app.)

Now tell the bridge the camera is adopted, so it stops asking Protect for adoption tokens:

```sh
nano cameras/driveway.env      # change ADOPTED=0 to ADOPTED=1, save
./bridge.sh up
```

Done. The bridge starts by itself after a reboot or power cut.

---

## Everyday

| Want to… | Type |
|---|---|
| see what's running | `./bridge.sh status` |
| watch one camera's log | `./bridge.sh logs driveway` |
| restart one camera | `./bridge.sh restart driveway` |
| stop everything | `./bridge.sh down` |
| start everything | `./bridge.sh up` |
| update to the newest code | `cd ~/reolink-unifi-protect && git pull && cd deploy/pi && ./bridge.sh up` |
| add a camera | new file in `cameras/`, own ports, `./bridge.sh up`, adopt, `ADOPTED=1`, `./bridge.sh up` |
| remove a camera | `./bridge.sh down backyard`, delete the file, remove the camera in Protect |

---

## If something doesn't work

**"UVC G5 Pro" never shows up in Protect.** `./bridge.sh logs driveway` and read the first
error. Usual causes: wrong `NVR_IP`; wrong Protect user/password (the user must be *local*
and *Administrator*); the Pi can't reach the camera (`ping CAMERA-IP`); RTSP/Camera Account
not enabled on the camera.

**Adopted, but no video / "Camera disconnected".** The `HI_*` / `LO_*` numbers don't match the
real streams, or the clock is off. Run the ffprobe check above, fix the numbers, then in
Protect **remove** the camera and adopt it again (Protect caches resolution at adoption).

**Video stutters / restarts every 15 s.** Something else is pulling the camera's RTSP
(Protect's own 3rd-party entry, the Tapo app's live view, Home Assistant) — a Tapo only allows
two sessions. Or the Pi is on WiFi. Or the log says `RTP packets lost`: fix the camera's WiFi
signal (an AP closer, a less crowded 2.4 GHz channel).

**Live view works but no events at all from one camera.** First check the Tapo app: Settings →
Detection — Tapo cameras have been seen to turn Person detection *off* by themselves (after a
firmware update, or when the camera's event engine wedges), and the app may just spin when you
try to turn it back on. The cure is a **full power cycle** (unplug 10 s), not the app's reboot
button. The bridge reconnects by itself when the camera comes back; `./bridge.sh logs <camera>`
shows `push-subscribed` followed by `person detected` on your next walk-by.

**One walk-by shows up as several short events, and the later ones show an empty yard.**
The camera paused longer between detections than `ONVIF_HOLD` (default 5 s). Set
`ONVIF_HOLD=8` (or 10) in that camera's file and `./bridge.sh up`. The price is a slightly
longer empty tail at the end of each clip.

**Events arrive but no thumbnails.** `./bridge.sh logs driveway` → look for `Motion thumbnail`
and `Object crop ready`. If you see "finished after the event ended", lower `THUMBNAIL_DELAY`
to 3 in the camera file.

**Live view flickers "Live view did not load" in Safari only.** `FFMPEG_ARGS` must contain
`-ar 16000` (the example does). If the log shows `SEI type ... truncated`, add
`-bsf:v filter_units=remove_types=6` after `-c:v copy` in `FFMPEG_ARGS`.

**Protect updated and now the camera flaps / offers an update.** Set `FW_VERSION` in the
camera file to the current G5 Pro firmware from
`https://fw-update.ui.com/api/firmware-latest?filter=eq~~platform~~sav837gw&filter=eq~~product~~uvc`
(the `version` field), then `./bridge.sh up`.

**Protect updated and smart detections stopped (plain motion only).** Protect changed the
camera protocol. On the console, SSH in and run
`grep -i "not expected\|Failed to parse" /volume/*/.srv/ds/logs/ds.log | tail` — open an
issue on GitHub with that line.

**The Pi is slow / hot.** `uptime` shows the load; under 3 on a Pi 4 is fine for two cameras.
Lower the cameras' sub streams to 15 fps / 1 Mbps in the Tapo app; make sure the case has
airflow.

---

## Moving from the macOS kit

If you were running the Mac version, copy its config instead of typing it: on the Mac,
`~/Library/Application Support/reolink-unifi-protect/` holds `.env`, `cameras/` and
`client.pem`. Copy that folder to the Pi (e.g. `scp -r` into `/tmp/mac-config`), then on the Pi:

```sh
./import-mac-config.sh /tmp/mac-config && rm -rf /tmp/mac-config
```

Stop the Mac's services **first** (`Stop.command`), then `./bridge.sh up`. Protect keeps the
cameras and their history because the MACs are the same.
