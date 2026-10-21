#!/usr/bin/env python3
"""Try several PullMessages request variants against a camera and report what it answers.
Usage: onvif_diag.py --host IP --user U --password P [--port 2020]"""
import argparse, asyncio, http.client, re, sys, time
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location("sc", pathlib.Path(__file__).with_name("onvif_sidecar.py"))
sc = importlib.util.module_from_spec(spec); spec.loader.exec_module(sc)

PULL = '<tev:PullMessages xmlns:tev="http://www.onvif.org/ver10/events/wsdl"><tev:Timeout>PT{t}S</tev:Timeout><tev:MessageLimit>10</tev:MessageLimit></tev:PullMessages>'
ACTION = "http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest"

def raw_post(host, port, path, xml, headers):
    c = http.client.HTTPConnection(host, port, timeout=20)
    c.request("POST", path, body=xml.encode(), headers=headers)
    r = c.getresponse(); data = r.read(); c.close()
    return r.status, data.decode(errors="replace")

def main():
    p = argparse.ArgumentParser(); p.add_argument("--host", required=True); p.add_argument("--port", type=int, default=2020)
    p.add_argument("--user", required=True); p.add_argument("--password", required=True); a = p.parse_args()
    import aiohttp
    async def go():
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(force_close=True)) as s:
            ev = sc.OnvifEvents(a.host, a.port, a.user, a.password); ev.session = s
            await ev.connect()
            sub = ev.sub_url; path = re.sub(r"^http://[^/]+", "", sub)
            print("subscription:", sub, flush=True)
            variants = [
                ("wsa+action-hdr, PT10S", sc.envelope(a.user, a.password, PULL.format(t=10), to=sub, action=ACTION), {"Content-Type": f'application/soap+xml; charset=utf-8; action="{ACTION}"', "Connection": "close"}),
                ("wsa, no action hdr, PT5S", sc.envelope(a.user, a.password, PULL.format(t=5), to=sub, action=ACTION), {"Content-Type": "application/soap+xml; charset=utf-8", "Connection": "close"}),
                ("no wsa, PT5S", sc.envelope(a.user, a.password, PULL.format(t=5)), {"Content-Type": "application/soap+xml; charset=utf-8", "Connection": "close"}),
                ("no wsa, PT1S", sc.envelope(a.user, a.password, PULL.format(t=1)), {"Content-Type": "application/soap+xml; charset=utf-8", "Connection": "close"}),
                ("no wsa, PT1S, text/xml", sc.envelope(a.user, a.password, PULL.format(t=1)), {"Content-Type": "text/xml; charset=utf-8", "Connection": "close"}),
                ("to events_url not sub, wsa, PT2S", sc.envelope(a.user, a.password, PULL.format(t=2), to=sub, action=ACTION), {"Content-Type": "application/soap+xml; charset=utf-8", "Connection": "close", "__url": ev.events_url}),
            ]
            for name, xml, hdr in variants:
                url_path = path
                if "__url" in hdr:
                    url_path = re.sub(r"^http://[^/]+", "", hdr.pop("__url"))
                t0 = time.time()
                try:
                    st, body = raw_post(a.host, a.port, url_path, xml, hdr)
                    summary = re.sub(r"\s+", " ", body)[:400]
                    print(f"[{name}] HTTP {st} in {time.time()-t0:.1f}s: {summary}", flush=True)
                except Exception as e:
                    print(f"[{name}] ERROR {type(e).__name__}: {e} after {time.time()-t0:.1f}s", flush=True)
            if hasattr(ev, "unsubscribe"): await ev.unsubscribe()
    asyncio.run(go())

if __name__ == "__main__":
    main()
