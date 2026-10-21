# ONVIF camera (Tapo etc.) → UniFi Protect with Docker

The Docker equivalent of [`deploy/macos`](../macos): the proxy, the ONVIF event sidecar and a
mediamtx RTSP relay, one stack per camera. Read [`../macos/README.md`](../macos/README.md) for
the why (Protect 7's Device Service, the two-session limit, the relay) — this file is only the
how.

Requirements: a Docker host on the same LAN as the camera and the NVR (the camera must be able
to reach the host on `PUSH_PORT`), accurate NTP on the host, and for Tapo a **Camera Account**
created in the Tapo app (Settings → Advanced Settings → Camera Account) — that, not your TP-Link
login, is what RTSP and ONVIF use.

```bash
git clone https://github.com/btsubjectdata/reolink-unifi-protect.git
cd reolink-unifi-protect/deploy/onvif
openssl req -x509 -newkey rsa:2048 -nodes -keyout client.key -out client.crt -days 36500 -subj "/CN=unifi-cam-proxy" \
  && cat client.key client.crt > client.pem && rm client.key client.crt
cp .env.example .env     # fill in NVR + camera; check the stream numbers with ffprobe
docker compose up -d --build
docker compose logs -f proxy
```

Within ~10 s the proxy connects to the NVR; the camera appears in Protect → Devices as an
unadopted **UVC G5 Pro** with your `CAM_NAME`. Adopt it. Enhanced encoding stays **off** for
H.264 cameras. Then, in Protect's camera settings, enable the Person / Vehicle / Animal object
types, and walk past the camera: `docker compose logs sidecar` shows `person detected`, the
proxy logs `Triggering motion start … for person`, and Protect shows a Person event.

Once adopted, set `ADOPTED=1` in `.env` and `docker compose up -d` so the proxy reconnects like
a real camera (no token / NVR login on every restart).

Second camera: copy the folder, use different `RELAY_PORT` / `AI_SINK_PORT` / `SNAPSHOT_PORT` /
`PUSH_PORT`, and `docker compose -p <name> up -d`.

Things that bite — the Tapo notes in [`../macos/README.md`](../macos/README.md#things-that-bite)
all apply (two RTSP sessions, turn off Protect's own *Discover 3rd-Party Cameras*, never click
"Click to Update", tiny ONVIF subscription table). `docker compose logs relay` says
`no route to host` → the host can't reach the camera; `Timed out waiting for <MAC>_2 to open`
in Protect's `video.recording.log` → something else holds a camera RTSP session.
