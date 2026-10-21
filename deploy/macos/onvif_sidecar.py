#!/usr/bin/env python3
"""ONVIF smart-detection sidecar for reolink-unifi-protect.

Subscribes to a camera's ONVIF event stream (PullPoint) and turns its own
person / vehicle / pet detections into box reports for the proxy's AI sink
(POST http://127.0.0.1:<port>/detections  {"boxes":[{type,coord,confidence}]}).

Built for TP-Link Tapo (ONVIF on port 2020, Camera Account credentials) but
the SOAP is plain ONVIF, so most cameras that publish RuleEngine events work.
Tapo publishes event-level detections only (no coordinates), so each active
class is reported as one fixed, centred box; run the proxy with
--ai-min-movement 0 so the stationary-box filter does not swallow it.

Usage:
  onvif_sidecar.py --host IP [--port 2020] --user U --password P --sink URL
  onvif_sidecar.py --host IP --user U --password P --dump 60   # print raw events
"""

import argparse
import asyncio
import base64
import hashlib
import json
import os
import pathlib
import re
import time
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

import aiohttp

# topic / item-name fragments -> Protect class
CLASS_RULES = [
    (re.compile(r"people|person|human|pedestrian", re.I), "person"),
    (re.compile(r"vehicle|car", re.I), "vehicle"),
    (re.compile(r"pet|animal|dog|cat", re.I), "animal"),
]
# Where the fixed box sits (Protect 0-1000 space, [x, y, w, h]) per class.
BOX = {
    "person": [350, 150, 300, 700],
    "vehicle": [200, 300, 600, 500],
    "animal": [350, 450, 300, 400],
}
CONF = 0.9


def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}] {msg}", flush=True)


def ws_security(user: str, password: str) -> str:
    nonce = os.urandom(16)
    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    digest = base64.b64encode(
        hashlib.sha1(nonce + created.encode() + password.encode()).digest()
    ).decode()
    return f"""<wsse:Security s:mustUnderstand="1"
      xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
      xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
      <wsse:UsernameToken>
        <wsse:Username>{user}</wsse:Username>
        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{digest}</wsse:Password>
        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">{base64.b64encode(nonce).decode()}</wsse:Nonce>
        <wsu:Created>{created}</wsu:Created>
      </wsse:UsernameToken>
    </wsse:Security>"""


def envelope(
    user: str,
    password: str,
    body: str,
    to: str | None = None,
    action: str | None = None,
) -> str:
    addressing = ""
    if to:
        addressing = f"""<wsa:To xmlns:wsa="http://www.w3.org/2005/08/addressing">{to}</wsa:To>
      <wsa:Action xmlns:wsa="http://www.w3.org/2005/08/addressing">{action}</wsa:Action>
      <wsa:MessageID xmlns:wsa="http://www.w3.org/2005/08/addressing">urn:uuid:{uuid.uuid4()}</wsa:MessageID>
      <wsa:ReplyTo xmlns:wsa="http://www.w3.org/2005/08/addressing"><wsa:Address>http://www.w3.org/2005/08/addressing/anonymous</wsa:Address></wsa:ReplyTo>"""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>{ws_security(user, password)}{addressing}</s:Header>
  <s:Body>{body}</s:Body>
</s:Envelope>"""


def strip_ns(tag: str) -> str:
    return tag.split("}", 1)[1] if "}" in tag else tag


class OnvifEvents:
    def __init__(self, host: str, port: int, user: str, password: str):
        self.host, self.port, self.user, self.password = host, port, user, password
        self.device_url = f"http://{host}:{port}/onvif/device_service"
        self.events_url: str | None = None
        self.sub_url: str | None = None
        self.session: aiohttp.ClientSession | None = None

    async def soap(
        self, url: str, body: str, action: str | None = None, to: str | None = None
    ) -> ET.Element:
        xml = envelope(self.user, self.password, body, to=to, action=action)
        headers = {
            "Content-Type": "application/soap+xml; charset=utf-8"
            + (f'; action="{action}"' if action else "")
        }
        async with self.session.post(
            url,
            data=xml.encode(),
            headers=headers,
            timeout=aiohttp.ClientTimeout(total=30),
        ) as r:
            text = await r.text()
            if r.status >= 400 and "Fault" not in text:
                raise RuntimeError(f"HTTP {r.status} from {url}: {text[:300]}")
        root = ET.fromstring(text)
        fault = root.find(".//{http://www.w3.org/2003/05/soap-envelope}Fault")
        if fault is not None:
            raise RuntimeError(
                "SOAP fault: "
                + " ".join(t.strip() for t in fault.itertext() if t.strip())[:300]
            )
        return root

    async def connect(self) -> None:
        root = await self.soap(
            self.device_url,
            '<tds:GetCapabilities xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><tds:Category>Events</tds:Category></tds:GetCapabilities>',
        )
        xaddr = None
        for el in root.iter():
            if strip_ns(el.tag) == "Events":
                for c in el:
                    if strip_ns(c.tag) == "XAddr":
                        xaddr = (c.text or "").strip()
        if not xaddr:
            raise RuntimeError("camera reports no Events service")
        # Some cameras advertise a hostname/port that is not what we dialled; keep our host.
        xaddr = re.sub(r"^http://[^/]+", f"http://{self.host}:{self.port}", xaddr)
        self.events_url = xaddr
        root = await self.soap(
            self.events_url,
            '<tev:CreatePullPointSubscription xmlns:tev="http://www.onvif.org/ver10/events/wsdl"><tev:InitialTerminationTime>PT120S</tev:InitialTerminationTime></tev:CreatePullPointSubscription>',
            action="http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest",
        )
        addr = None
        for el in root.iter():
            if strip_ns(el.tag) == "SubscriptionReference":
                for c in el.iter():
                    if strip_ns(c.tag) == "Address":
                        addr = (c.text or "").strip()
        if not addr:
            raise RuntimeError(
                "no SubscriptionReference in CreatePullPointSubscription response"
            )
        self.sub_url = re.sub(r"^http://[^/]+", f"http://{self.host}:{self.port}", addr)
        log(f"subscribed: events={self.events_url} subscription={self.sub_url}")

    async def pull(self, timeout_s: int = 10) -> list[dict]:
        root = await self.soap(
            self.sub_url,
            f'<tev:PullMessages xmlns:tev="http://www.onvif.org/ver10/events/wsdl"><tev:Timeout>PT{timeout_s}S</tev:Timeout><tev:MessageLimit>100</tev:MessageLimit></tev:PullMessages>',
            action="http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest",
            to=self.sub_url,
        )
        return parse_notifications(root)

    async def snapshot_uri(self) -> str | None:
        """ONVIF Media GetProfiles -> GetSnapshotUri of the first profile (None if unsupported)."""
        root = await self.soap(
            self.device_url,
            '<tds:GetCapabilities xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><tds:Category>Media</tds:Category></tds:GetCapabilities>',
        )
        media = None
        for el in root.iter():
            if strip_ns(el.tag) == "Media":
                for c in el:
                    if strip_ns(c.tag) == "XAddr":
                        media = (c.text or "").strip()
        if not media:
            return None
        media = re.sub(r"^http://[^/]+", f"http://{self.host}:{self.port}", media)
        root = await self.soap(
            media,
            '<trt:GetProfiles xmlns:trt="http://www.onvif.org/ver10/media/wsdl"/>',
        )
        token = None
        for el in root.iter():
            if strip_ns(el.tag) == "Profiles" and el.get("token"):
                token = el.get("token")
                break
        if not token:
            return None
        root = await self.soap(
            media,
            f'<trt:GetSnapshotUri xmlns:trt="http://www.onvif.org/ver10/media/wsdl"><trt:ProfileToken>{token}</trt:ProfileToken></trt:GetSnapshotUri>',
        )
        for el in root.iter():
            if strip_ns(el.tag) == "Uri":
                return re.sub(
                    r"^http://[^/]+",
                    f"http://{self.host}:{self.port}",
                    (el.text or "").strip(),
                )
        return None

    async def connect_push(self, consumer_url: str) -> None:
        """WS-BaseNotification Subscribe: the camera POSTs Notify messages to consumer_url.
        Tapo's pull point hangs up on every PullMessages, but push works (HA does the same).
        """
        if not self.events_url:
            root = await self.soap(
                self.device_url,
                '<tds:GetCapabilities xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><tds:Category>Events</tds:Category></tds:GetCapabilities>',
            )
            xaddr = None
            for el in root.iter():
                if strip_ns(el.tag) == "Events":
                    for c in el:
                        if strip_ns(c.tag) == "XAddr":
                            xaddr = (c.text or "").strip()
            if not xaddr:
                raise RuntimeError("camera reports no Events service")
            self.events_url = re.sub(
                r"^http://[^/]+", f"http://{self.host}:{self.port}", xaddr
            )
        body = f"""<wsnt:Subscribe xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" xmlns:wsa="http://www.w3.org/2005/08/addressing">
          <wsnt:ConsumerReference><wsa:Address>{consumer_url}</wsa:Address></wsnt:ConsumerReference>
          <wsnt:InitialTerminationTime>PT120S</wsnt:InitialTerminationTime>
        </wsnt:Subscribe>"""
        root = await self.soap(
            self.events_url,
            body,
            action="http://docs.oasis-open.org/wsn/bw-2/NotificationProducer/SubscribeRequest",
            to=self.events_url,
        )
        addr = None
        for el in root.iter():
            if strip_ns(el.tag) == "SubscriptionReference":
                for c in el.iter():
                    if strip_ns(c.tag) == "Address":
                        addr = (c.text or "").strip()
        if not addr:
            raise RuntimeError("no SubscriptionReference in Subscribe response")
        self.sub_url = re.sub(r"^http://[^/]+", f"http://{self.host}:{self.port}", addr)
        log(f"push-subscribed: consumer={consumer_url} subscription={self.sub_url}")

    async def unsubscribe(self) -> None:
        """Release the pull point. Tapo keeps a small, fixed table of subscriptions and
        refuses new ones (InvalidArgVal) while leaked ones have not expired."""
        if not self.sub_url:
            return
        try:
            await self.soap(
                self.sub_url,
                '<wsnt:Unsubscribe xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"/>',
                action="http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/UnsubscribeRequest",
                to=self.sub_url,
            )
            log("unsubscribed")
        except Exception as e:
            log(f"unsubscribe failed: {e}")
        self.sub_url = None

    async def renew(self) -> None:
        await self.soap(
            self.sub_url,
            '<wsnt:Renew xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"><wsnt:TerminationTime>PT120S</wsnt:TerminationTime></wsnt:Renew>',
            action="http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/RenewRequest",
            to=self.sub_url,
        )


def parse_notifications(root: ET.Element) -> list[dict]:
    out = []
    for nm in root.iter():
        if strip_ns(nm.tag) != "NotificationMessage":
            continue
        topic = ""
        items = {}
        for el in nm.iter():
            t = strip_ns(el.tag)
            if t == "Topic":
                topic = (el.text or "").strip()
            elif t == "SimpleItem":
                items[el.get("Name", "")] = el.get("Value", "")
        out.append({"topic": topic, "items": items})
    return out


def local_ip_towards(host: str) -> str:
    import socket

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((host, 9))
        return s.getsockname()[0]
    finally:
        s.close()


def classify(topic: str, items: dict) -> list[tuple[str, bool]]:
    """-> [(class, active)] for one notification. Unknown topics -> []."""

    def truthy(v):
        return str(v).strip().lower() in ("true", "1", "on")

    results = []
    # 1. per-item names like IsPeople / IsVehicle / IsPet (Tapo TPSmartEvent style)
    for name, value in items.items():
        for rx, cls in CLASS_RULES:
            if rx.search(name):
                results.append((cls, truthy(value)))
                break
    if results:
        return results
    # 2. topic names like RuleEngine/PeopleDetector/People with a State/IsXxx item
    for rx, cls in CLASS_RULES:
        if rx.search(topic):
            state = next(
                (
                    v
                    for k, v in items.items()
                    if k.lower() in ("state", "ismotion", "isinside", "value")
                ),
                None,
            )
            if state is None and items:
                state = list(items.values())[-1]
            return [(cls, truthy(state) if state is not None else True)]
    return []


async def run(args: argparse.Namespace) -> None:
    active: dict[str, float] = {}  # class -> time it was last reported active
    HOLD = (
        args.hold
    )  # seconds a class stays "present" after its last active notification

    async def poster(session: aiohttp.ClientSession):
        while True:
            now = time.time()
            boxes = [
                {"type": cls, "coord": BOX[cls], "confidence": CONF}
                for cls, ts in active.items()
                if now - ts < HOLD
            ]
            try:
                await session.post(
                    args.sink,
                    json={"boxes": boxes},
                    timeout=aiohttp.ClientTimeout(total=2),
                )
            except Exception as e:  # proxy restarting — keep going
                if int(now) % 30 == 0:
                    log(f"sink unreachable: {e}")
            await asyncio.sleep(args.interval)

    # Tapo closes the TCP connection after every SOAP reply; a reused keep-alive socket
    # then fails with "Server disconnected". Force a fresh connection per request.
    async with aiohttp.ClientSession(
        connector=aiohttp.TCPConnector(force_close=True)
    ) as session:
        ev = OnvifEvents(args.host, args.port, args.user, args.password)
        ev.session = session
        if not args.dump:
            asyncio.create_task(poster(session))
        if args.snapshot_port or args.dump:
            await serve_snapshots(args, ev, session)
        seen = set()

        last_event = {"ts": time.time()}

        def handle(msgs):
            if msgs:
                last_event["ts"] = time.time()
            for m in msgs:
                if args.dump:
                    log(f"EVENT topic={m['topic']} items={json.dumps(m['items'])}")
                for cls, on in classify(m["topic"], m["items"]):
                    if on:
                        if cls not in active or time.time() - active[cls] >= HOLD:
                            log(f"{cls} detected ({m['topic']})")
                        active[cls] = time.time()
                    else:
                        active.pop(cls, None)
                if not args.dump and m["topic"] not in seen:
                    seen.add(m["topic"])
                    log(f"topic seen: {m['topic']} items={json.dumps(m['items'])}")

        if args.mode == "push":
            from aiohttp import web

            async def notify(request):
                try:
                    root = ET.fromstring(await request.read())
                    handle(parse_notifications(root))
                except Exception as e:
                    log(f"bad notify: {e}")
                return web.Response(text="")

            app = web.Application()
            app.add_routes([web.post("/notify", notify), web.post("/", notify)])
            runner = web.AppRunner(app)
            await runner.setup()
            await web.TCPSite(runner, "0.0.0.0", args.push_port).start()
            my_ip = args.push_host or local_ip_towards(args.host)
            consumer = f"http://{my_ip}:{args.push_port}/notify"
            log(f"listening for camera notifications on {consumer}")
            backoff = 2
            started = time.time()
            while True:
                try:
                    await ev.connect_push(consumer)
                    backoff = 2
                    last_event["ts"] = subscribed_at = time.time()
                    while True:
                        await asyncio.sleep(60)
                        if args.dump and time.time() - started > args.dump:
                            log("dump finished")
                            await ev.unsubscribe()
                            return
                        # A rebooted Tapo forgets its subscriptions but still answers
                        # Renew, so a quiet camera looks like a live one. Re-create the
                        # subscription when nothing has arrived for a while (a Tapo sends
                        # motion on/off notifications regularly) and on a fixed cadence.
                        quiet = time.time() - last_event["ts"]
                        age = time.time() - subscribed_at
                        if (
                            quiet > args.resubscribe_quiet
                            or age > args.resubscribe_every
                        ):
                            log(
                                f"re-creating subscription ({int(quiet)}s without a"
                                f" notification, {int(age)}s old)"
                            )
                            await ev.unsubscribe()
                            break
                        await ev.renew()
                except asyncio.CancelledError:
                    await ev.unsubscribe()
                    raise
                except Exception as e:
                    await ev.unsubscribe()
                    if "InvalidArgVal" in str(e):
                        backoff = max(backoff, 30)
                    log(f"ONVIF error: {e} — resubscribing in {backoff}s")
                    await asyncio.sleep(backoff)
                    backoff = min(backoff * 2, 120)

        backoff = 2
        while True:
            try:
                await ev.connect()
                backoff = 2
                last_renew = time.time()
                started = time.time()
                while True:
                    handle(await ev.pull(10))
                    if time.time() - last_renew > 60:
                        await ev.renew()
                        last_renew = time.time()
                    if args.dump and time.time() - started > args.dump:
                        log("dump finished")
                        await ev.unsubscribe()
                        return
            except asyncio.CancelledError:
                await ev.unsubscribe()
                raise
            except Exception as e:
                await ev.unsubscribe()
                if "InvalidArgVal" in str(e):
                    backoff = max(
                        backoff, 30
                    )  # subscription table full; let stale ones expire
                log(f"ONVIF error: {e} — reconnecting in {backoff}s")
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 120)


async def serve_snapshots(
    args, ev: "OnvifEvents", session: aiohttp.ClientSession
) -> None:
    """GET /snapshot.jpg on 127.0.0.1:<snapshot_port> -> the camera's ONVIF snapshot.

    Lets the proxy use --snapshot-url instead of a third always-on RTSP session
    (Tapo caps concurrent RTSP sessions). Falls back to 503 if the camera has no
    snapshot URI; the proxy then just reports "not ready".
    """
    from aiohttp import web

    state = {"uri": None, "checked": 0.0}

    async def uri() -> str | None:
        if state["uri"] is None and time.time() - state["checked"] > 3600:
            state["checked"] = time.time()
            try:
                state["uri"] = await ev.snapshot_uri()
                log(f"snapshot uri: {state['uri']}")
            except Exception as e:
                log(f"snapshot uri lookup failed: {e}")
        return state["uri"]

    if args.dump:
        u = await uri()
        if u:
            try:
                async with session.get(
                    u,
                    auth=aiohttp.BasicAuth(args.user, args.password),
                    timeout=aiohttp.ClientTimeout(total=10),
                ) as r:
                    data = await r.read()
                    log(
                        f"snapshot fetch: HTTP {r.status} {r.headers.get('Content-Type')} {len(data)} bytes"
                    )
            except Exception as e:
                log(f"snapshot fetch failed: {e}")
        return

    cache = {"ts": 0.0, "data": b""}
    lock = asyncio.Lock()

    async def grab_rtsp() -> bytes:
        """One JPEG from the sub stream via a short-lived ffmpeg RTSP session (cameras with
        no ONVIF snapshot, e.g. Tapo). Cached for a few seconds so Protect's polling does not
        open a session per request."""
        if not args.rtsp_snapshot_url:
            return b""
        async with lock:
            if time.time() - cache["ts"] < 4 and cache["data"]:
                return cache["data"]
            proc = await asyncio.create_subprocess_exec(
                "ffmpeg",
                "-nostdin",
                "-loglevel",
                "error",
                "-rtsp_transport",
                "tcp",
                "-i",
                args.rtsp_snapshot_url,
                "-frames:v",
                "1",
                "-q:v",
                "4",
                "-f",
                "image2",
                "pipe:1",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            try:
                data, _ = await asyncio.wait_for(proc.communicate(), timeout=12)
            except asyncio.TimeoutError:
                proc.kill()
                return cache["data"]
            if data:
                cache["ts"], cache["data"] = time.time(), data
            return cache["data"]

    async def handler(request):
        # 1. a JPEG the proxy's own stream ffmpeg keeps updated (no extra RTSP session)
        if args.snapshot_file:
            try:
                p = pathlib.Path(args.snapshot_file)
                if time.time() - p.stat().st_mtime < 30:
                    data = p.read_bytes()
                    if data[:2] == b"\xff\xd8" and data.rstrip()[-2:] == b"\xff\xd9":
                        return web.Response(body=data, content_type="image/jpeg")
            except FileNotFoundError:
                pass
            except Exception as e:
                log(f"snapshot file read failed: {e}")
        u = await uri()
        if u:
            try:
                async with session.get(
                    u,
                    auth=aiohttp.BasicAuth(args.user, args.password),
                    timeout=aiohttp.ClientTimeout(total=10),
                ) as r:
                    data = await r.read()
                    if r.status == 200 and data:
                        return web.Response(body=data, content_type="image/jpeg")
            except Exception as e:
                log(f"onvif snapshot failed: {e}")
        if args.snapshot_file:
            # never open an extra RTSP session when a tee file is configured
            return web.Response(status=503, text="snapshot file not ready")
        data = await grab_rtsp()
        if not data:
            return web.Response(status=503, text="no snapshot available")
        return web.Response(body=data, content_type="image/jpeg")

    app = web.Application()
    app.add_routes([web.get("/snapshot.jpg", handler)])
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", args.snapshot_port).start()
    log(f"snapshot server on http://127.0.0.1:{args.snapshot_port}/snapshot.jpg")


def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=2020)
    p.add_argument("--user", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--sink", default="http://127.0.0.1:7999/detections")
    p.add_argument(
        "--interval", type=float, default=0.4, help="seconds between sink posts"
    )
    p.add_argument(
        "--resubscribe-quiet",
        type=float,
        default=300,
        help="re-create the push subscription after this many seconds without any notification (a rebooted camera forgets it but still answers Renew)",
    )
    p.add_argument(
        "--resubscribe-every",
        type=float,
        default=1800,
        help="re-create the push subscription at least this often (seconds)",
    )
    p.add_argument(
        "--hold",
        type=float,
        default=4.0,
        help="seconds a class stays present after its last 'true' notification (Tapo repeats them every 1-4 s; a 'false' clears it at once)",
    )
    p.add_argument(
        "--mode",
        choices=("push", "pull"),
        default="push",
        help="push: camera POSTs events to us (Tapo needs this); pull: ONVIF PullPoint",
    )
    p.add_argument(
        "--push-port",
        type=int,
        default=0,
        help="local port the camera posts events to (default: sink port + 2000)",
    )
    p.add_argument(
        "--push-host",
        default="",
        help="our IP as the camera should see it (default: auto)",
    )
    p.add_argument(
        "--snapshot-file",
        default="",
        help="serve this JPEG (kept fresh by the proxy's --snapshot-tee) at /snapshot.jpg",
    )
    p.add_argument(
        "--rtsp-snapshot-url",
        default="",
        help="RTSP URL (sub stream) to grab a frame from when the camera has no ONVIF snapshot",
    )
    p.add_argument(
        "--snapshot-port",
        type=int,
        default=0,
        help="serve the camera's ONVIF snapshot at /snapshot.jpg on this local port",
    )
    p.add_argument(
        "--dump",
        type=int,
        default=0,
        metavar="SECONDS",
        help="print raw events for N seconds and exit",
    )
    args = p.parse_args()
    if not args.push_port:
        m = re.search(r":(\d+)/", args.sink)
        args.push_port = (int(m.group(1)) if m else 7999) + 2000
    import signal

    async def runner():
        task = asyncio.ensure_future(run(args))
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, task.cancel)
        try:
            await task
        except asyncio.CancelledError:
            pass

    asyncio.run(runner())


if __name__ == "__main__":
    main()
