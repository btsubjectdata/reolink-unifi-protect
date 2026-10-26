"""The Reolink encrypted API transport, against a fake camera that speaks the
protocol of the Elite Floodlight's web UI (firmware v3.2.0.6011)."""

import hashlib
import json
import logging
import re

import pytest

from unifi.reolink_api import ReolinkApi, _Cipher, parse_www_authenticate

NONCE = "22c1636b1f4c3f1a9a0d2bb3"
USER, PASSWORD = "bridge", "s3cret"


def parse_qs(query) -> dict[str, list[str]]:
    # not urllib's: the base64 must not have '+' turned into spaces
    out: dict[str, list[str]] = {}
    for part in str(query).split("&"):
        k, _, v = part.partition("=")
        out.setdefault(k, []).append(v)
    return out


def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


class FakeSecureCamera:
    """Answers like a 2026 Reolink: digest challenge, AES bodies, check numbers."""

    def __init__(self) -> None:
        self.cipher = None
        self.seen: dict[int, int] = {}
        self.calls: list[tuple[str, dict]] = []
        self.logins = 0

    async def request(self, method, query, data):
        q = parse_qs(query)
        if q.get("cmd") == ["Login"]:
            body = json.loads(data)[0]
            if "Digest" not in body["param"]:
                hdr = {
                    "WWW-Authenticate": f'Digest qop="auth", realm="IPC", nonce="{NONCE}", stale="FALSE", nc=00000002'
                }
                return 200, hdr, json.dumps([{"cmd": "Login", "code": 1}]).encode()
            d = body["param"]["Digest"]
            ha1 = md5(f"{USER}:IPC:{PASSWORD}")
            ha2 = md5("POST:cgi-bin/api.cgi?cmd=Login")
            expect = md5(f"{ha1}:{NONCE}:00000002:{d['Cnonce']}:auth:{ha2}")
            if d["Response"] != expect:
                return 200, {}, json.dumps([{"cmd": "Login", "code": 1, "error": {"rspCode": -7}}]).encode()
            self.cipher = _Cipher(
                md5(f"{NONCE}-{PASSWORD}-{d['Cnonce']}")[:16].upper(),
                md5(f"webapp-{d['Cnonce']}-{PASSWORD}-{NONCE}-{USER}")[:16].upper(),
            )
            self.logins += 1
            reply = [{"cmd": "Login", "code": 0, "value": {"Token": {"name": "tok1", "leaseTime": 3600, "checkBasic": 61, "countTotal": 32}}}]
            return 200, {}, self.cipher.encrypt(json.dumps(reply)).encode()
        assert q["token"] == ["tok1"]
        plain = parse_qs(self.cipher.decrypt(q["encrypt"][0]))
        slot, num = int(plain["countId"][0]), int(plain["checkNum"][0])
        if slot < 3 or num <= self.seen.get(slot, 61):
            return 200, {}, self.cipher.encrypt(json.dumps([{"cmd": "x", "code": 1, "error": {"rspCode": -104, "detail": "err check num"}}])).encode()
        self.seen[slot] = num
        if plain.get("cmd") == ["Snap"]:
            assert plain["snapType"] == ["sub"] and data is None
            return 200, {"Content-Type": "image/jpeg"}, b"\xff\xd8jpeg"
        cmds = json.loads(self.cipher.decrypt(data.decode()))
        self.calls.extend((c["cmd"], c["param"]) for c in cmds)
        reply = [{"cmd": c["cmd"], "code": 0, "value": {"ok": True}} for c in cmds]
        return 200, {}, self.cipher.encrypt(json.dumps(reply)).encode()


class FakePlainCamera:
    async def request(self, method, query, data):
        q = parse_qs(query)
        if q.get("cmd") == ["Login"]:
            body = json.loads(data)[0]
            if "User" not in body["param"]:
                return 200, {}, json.dumps([{"cmd": "Login", "code": 1, "error": {"rspCode": -9}}]).encode()
            assert body["param"]["User"]["password"] == PASSWORD
            return 200, {}, json.dumps([{"cmd": "Login", "code": 0, "value": {"Token": {"name": "plaintok"}}}]).encode()
        assert q["token"] == ["plaintok"] and "encrypt" not in q
        cmds = json.loads(data)
        return 200, {}, json.dumps([{"cmd": c["cmd"], "code": 0} for c in cmds]).encode()


def make_api(fake) -> ReolinkApi:
    api = ReolinkApi("cam", USER, PASSWORD, logging.getLogger("t"))
    api._request = fake.request  # type: ignore[assignment]
    return api


def test_parse_www_authenticate():
    f = parse_www_authenticate('Digest qop="auth", realm="IPC", nonce="abc", stale="FALSE", nc=00000002')
    assert f == {"qop": "auth", "realm": "IPC", "nonce": "abc", "stale": "FALSE", "nc": "00000002"}


def test_cipher_roundtrip_zero_padding():
    c = _Cipher("0123456789ABCDEF", "FEDCBA9876543210")
    for text in ("x", '[{"cmd":"GetDevInfo","action":0,"param":{}}]', "a" * 16):
        enc = c.encrypt(text)
        assert re.fullmatch(r"[A-Za-z0-9+/=]+", enc)
        assert c.decrypt(enc) == text


@pytest.mark.asyncio
async def test_digest_login_encrypted_commands_and_snapshot():
    cam = FakeSecureCamera()
    api = make_api(cam)
    res = await api.call_one("GetDevInfo")
    assert res["code"] == 0 and api.secure is True and cam.logins == 1
    res = await api.call([{"cmd": "SetWhiteLed", "param": {"WhiteLed": {"state": 1}}}, {"cmd": "GetIsp", "param": {}}])
    assert [r["code"] for r in res] == [0, 0]
    assert cam.calls[-2:] == [("SetWhiteLed", {"WhiteLed": {"state": 1}}), ("GetIsp", {})]
    assert await api.snapshot("sub") == b"\xff\xd8jpeg"
    assert cam.logins == 1  # one session for everything
    # every request used a fresh, increasing check number on a non-stream slot
    assert all(slot >= 3 for slot in cam.seen)


@pytest.mark.asyncio
async def test_check_numbers_never_repeat():
    cam = FakeSecureCamera()
    api = make_api(cam)
    for _ in range(200):
        assert (await api.call_one("GetDevInfo"))["code"] == 0


@pytest.mark.asyncio
async def test_plain_login_fallback_for_older_firmware():
    api = make_api(FakePlainCamera())
    res = await api.call_one("GetDevInfo")
    assert res["code"] == 0 and api.secure is False
