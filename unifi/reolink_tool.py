"""Small CLI for a Reolink camera's HTTP API (works with the 2025+ encrypted firmware).

    python -m unifi.reolink_tool --host 192.168.1.50 --user admin info
    python -m unifi.reolink_tool --host 192.168.1.50 --user admin add-user bridge
    python -m unifi.reolink_tool --host 192.168.1.50 --user bridge snapshot out.jpg [--stream sub]

The password is read from the REOLINK_PASS environment variable (never an argument, so it
stays out of shell history and process lists). ``add-user`` prints the generated password
once; put it in ``CAM_PASS``. From the deploy/n100 directory the tool runs inside the image:

    docker compose run --rm --entrypoint python -e REOLINK_PASS proxy -m unifi.reolink_tool ...
"""

import argparse
import asyncio
import base64
import json
import logging
import os
import sys

from unifi.reolink_api import ReolinkApi


async def run(args: argparse.Namespace) -> int:
    password = os.environ.get("REOLINK_PASS")
    if not password:
        print("set REOLINK_PASS to the camera password", file=sys.stderr)
        return 2
    api = ReolinkApi(args.host, args.user, password, logging.getLogger("reolink"))
    try:
        if args.command == "info":
            res = await api.call(
                [
                    {"cmd": "GetDevInfo", "param": {}},
                    {"cmd": "GetUser", "param": {}},
                    {"cmd": "GetOnline", "param": {}},
                ]
            )
            info = res[0].get("value", {}).get("DevInfo", {})
            print(f"api: {'encrypted (digest login)' if api.secure else 'plain login'}")
            print(
                f"model: {info.get('model')}  firmware: {info.get('firmVer')}"
                f"  hardware: {info.get('hardVer')}"
            )
            users = [u["userName"] for u in res[1].get("value", {}).get("User", [])]
            print(f"users: {', '.join(users) or res[1].get('error')}")
            online = res[2].get("value", {}).get("User", [])
            print(
                "sessions: "
                + ", ".join(f"{u.get('userName')}@{u.get('ip')}" for u in online)
            )
            # GetEnc: stream sizes for .env
            enc = await api.call_one("GetEnc", {"channel": 0})
            if enc.get("code") == 0:
                e = enc["value"]["Enc"]
                for name in ("mainStream", "subStream", "extStream"):
                    st = e.get(name)
                    if st:
                        print(
                            f"{name}: {st.get('vType')} {st.get('size')}"
                            f" @ {st.get('frameRate')} fps, {st.get('bitRate')} kbps"
                        )
        elif args.command == "add-user":
            new_password = (
                base64.b32encode(os.urandom(15)).decode().lower()
                if not args.password
                else args.password
            )
            res = await api.call_one(
                "AddUser",
                {
                    "User": {
                        "userName": args.name,
                        "password": new_password,
                        "level": "admin",
                    }
                },
            )
            if res.get("code") != 0:
                print(f"AddUser failed: {res.get('error')}", file=sys.stderr)
                return 1
            print(f"user '{args.name}' created; CAM_PASS={new_password}")
        elif args.command == "snapshot":
            data = await api.snapshot(args.stream)
            with open(args.out, "wb") as f:
                f.write(data)
            print(f"{len(data)} bytes -> {args.out}")
        elif args.command == "raw":
            res = await api.call_one(args.cmd, json.loads(args.param))
            print(json.dumps(res, indent=1))
        await api.logout()
        return 0
    finally:
        await api.close()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--host", required=True)
    p.add_argument("--user", required=True)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("info", help="model, firmware, users, sessions, stream sizes")
    a = sub.add_parser("add-user", help="create an admin user on the camera")
    a.add_argument("name")
    a.add_argument("--password", help="default: a random one, printed once")
    s = sub.add_parser("snapshot", help="save a JPEG")
    s.add_argument("out")
    s.add_argument("--stream", default="main", choices=["main", "sub", "ext"])
    r = sub.add_parser("raw", help="send one API command")
    r.add_argument("cmd")
    r.add_argument("param", nargs="?", default="{}")
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    sys.exit(asyncio.run(run(args)))


if __name__ == "__main__":
    main()
