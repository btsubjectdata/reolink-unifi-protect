"""Reolink HTTP(S) API transport: classic plain login and the encrypted "secure" API.

Firmware from 2025/2026 on (seen on an Elite Floodlight WiFi, v3.2.0.6011) refuses the
classic ``Login`` with a plaintext password (``login deny``, rspCode -503) and the
``cmd=Snap&user=&password=`` snapshot URL. Those cameras only speak the protocol of
their own web UI:

1. ``POST /cgi-bin/api.cgi?cmd=Login`` with ``param: {"Version": 1}`` answers with an
   HTTP-digest challenge in the ``WWW-Authenticate`` header (realm, nonce, nc, qop).
2. A second ``Login`` carries ``Digest: {UserName, Realm, Method: "POST", Uri:
   "cgi-bin/api.cgi?cmd=Login", Nonce, Nc, Cnonce, Qop, Response}`` with the usual
   RFC 2617 MD5 response and returns the token plus ``checkBasic``/``countTotal``.
3. Every later request body is ``base64(AES-128-CFB(json))`` with zero padding;
   key = ``md5(f"{nonce}-{password}-{cnonce}")[:16].upper()``, iv =
   ``md5(f"webapp-{cnonce}-{password}-{nonce}-{username}")[:16].upper()``. Replies are
   encrypted the same way (``application/json`` ones; a snapshot comes back as JPEG).
4. The query string is ``token=<token>&encrypt=<AES("countId=N&checkNum=M&cmd=X")>``:
   the camera hands out ``countTotal`` counter slots (ids 0-2 are reserved for the
   stream players), each starting at ``checkBasic`` and incremented per use; a reused
   or stale number is refused with ``err check num``.

Cameras on older firmware answer the challenge without a ``WWW-Authenticate`` header;
the client then falls back to the plain ``Version: "0"`` login and unencrypted bodies,
so the same code serves both generations.
"""

import asyncio
import base64
import hashlib
import json
import logging
import os
import random
from typing import Any, Optional

import aiohttp
from Cryptodome.Cipher import AES
from yarl import URL

# rspCode values that mean "log in again"
STALE_TOKEN_CODES = (-6, -7, -27, -502)
# ids 0-2 are used by the web UI for live view / playback / download and are not
# ours to burn
_FIRST_COMMAND_SLOT = 3


def _md5(text: str) -> str:
    return hashlib.md5(text.encode()).hexdigest()


class _Cipher:
    def __init__(self, key: str, iv: str) -> None:
        self._key = key.encode()
        self._iv = iv.encode()

    def _aes(self):
        return AES.new(self._key, AES.MODE_CFB, iv=self._iv, segment_size=128)

    def encrypt(self, text: str) -> str:
        raw = text.encode()
        raw += b"\x00" * (-len(raw) % 16)
        return base64.b64encode(self._aes().encrypt(raw)).decode()

    def decrypt(self, b64: str) -> str:
        return self._aes().decrypt(base64.b64decode(b64)).rstrip(b"\x00").decode()


def parse_www_authenticate(header: str) -> dict[str, str]:
    """``Digest realm="IPC", qop="auth", nonce="...", nc=00000002`` -> dict."""
    fields: dict[str, str] = {}
    body = header.strip()
    if body.lower().startswith("digest"):
        body = body[len("digest") :]
    for part in body.split(","):
        if "=" in part:
            key, value = part.strip().split("=", 1)
            fields[key.strip().lower()] = value.strip().strip('"')
    return fields


class ReolinkApi:
    """One camera, one kept-alive HTTPS connection, lazy login, automatic re-login."""

    LOGIN_URI = "cgi-bin/api.cgi?cmd=Login"

    def __init__(
        self,
        host: str,
        user: str,
        password: str,
        logger: logging.Logger,
        channel: int = 0,
        timeout: float = 10.0,
    ) -> None:
        self.host = host
        self.user = user
        self.password = password
        self.logger = logger
        self.channel = channel
        self.timeout = timeout
        self._token: Optional[str] = None
        self._session: Optional[aiohttp.ClientSession] = None
        self._lock = asyncio.Lock()
        self._cipher: Optional[_Cipher] = None
        self._counts: dict[int, int] = {}
        self.secure: Optional[bool] = None  # unknown until the first login

    # -- transport -------------------------------------------------------------------

    @property
    def _base(self) -> str:
        return f"https://{self.host}/cgi-bin/api.cgi"

    async def _request(
        self, method: str, query: str, data: Optional[bytes]
    ) -> tuple[int, "aiohttp.typedefs.CIMultiDictProxy", bytes]:
        # One kept-alive connection: a fresh TLS handshake per command made every
        # PtzCtrl take ~420 ms against ~100 ms reused.
        # encoded=True: the base64 in ``encrypt=`` must reach the camera byte for byte
        # (its web UI sends it raw); yarl would otherwise re-quote '+' and '/'.
        url = URL(f"{self._base}?{query}", encoded=True)
        headers = {"Content-Type": "application/json"} if data is not None else {}
        for attempt in (0, 1):
            if self._session is None or self._session.closed:
                self._session = aiohttp.ClientSession()
            try:
                async with self._session.request(
                    method,
                    url,
                    data=data,
                    headers=headers,
                    ssl=False,
                    timeout=aiohttp.ClientTimeout(total=self.timeout),
                ) as resp:
                    return resp.status, resp.headers, await resp.read()
            except (aiohttp.ServerDisconnectedError, aiohttp.ClientOSError):
                # The camera drops idle connections: reconnect once.
                await self.close()
                if attempt:
                    raise
        raise RuntimeError("unreachable")

    async def close(self) -> None:
        session, self._session = self._session, None
        if session is not None and not session.closed:
            await session.close()

    def _decode(self, raw: bytes) -> list:
        text = raw.decode(errors="replace")
        try:
            return json.loads(text)
        except ValueError:
            if self._cipher is None:
                raise
            return json.loads(self._cipher.decrypt(text))

    # -- login -----------------------------------------------------------------------

    async def _login(self) -> None:
        self._token = None
        self._cipher = None
        self._counts = {}
        challenge = json.dumps(
            [{"cmd": "Login", "action": 0, "param": {"Version": 1}}]
        ).encode()
        _, headers, raw = await self._request("POST", "cmd=Login", challenge)
        auth = headers.get("WWW-Authenticate")
        if auth and "nonce" in auth.lower():
            await self._login_digest(parse_www_authenticate(auth))
        else:
            await self._login_plain()

    async def _login_plain(self) -> None:
        body = [
            {
                "cmd": "Login",
                "action": 0,
                "param": {
                    "User": {
                        "Version": "0",
                        "userName": self.user,
                        "password": self.password,
                    }
                },
            }
        ]
        _, _, raw = await self._request("POST", "cmd=Login", json.dumps(body).encode())
        res = json.loads(raw)
        if res[0].get("code") != 0:
            raise RuntimeError(f"Reolink login failed: {res[0].get('error')}")
        self._token = res[0]["value"]["Token"]["name"]
        self.secure = False
        self.logger.debug("Reolink %s: plain login", self.host)

    async def _login_digest(self, fields: dict[str, str]) -> None:
        realm = fields.get("realm", "")
        nonce = fields["nonce"]
        nc = fields.get("nc", "00000001")
        qop = fields.get("qop", "auth")
        cnonce = os.urandom(24).hex()
        ha1 = _md5(f"{self.user}:{realm}:{self.password}")
        ha2 = _md5(f"POST:{self.LOGIN_URI}")
        response = _md5(f"{ha1}:{nonce}:{nc}:{cnonce}:{qop}:{ha2}")
        cipher = _Cipher(
            _md5(f"{nonce}-{self.password}-{cnonce}")[:16].upper(),
            _md5(f"webapp-{cnonce}-{self.password}-{nonce}-{self.user}")[:16].upper(),
        )
        body = [
            {
                "cmd": "Login",
                "action": 0,
                "param": {
                    "Version": 1,
                    "Digest": {
                        "UserName": self.user,
                        "Realm": realm,
                        "Method": "POST",
                        "Uri": self.LOGIN_URI,
                        "Nonce": nonce,
                        "Nc": nc,
                        "Cnonce": cnonce,
                        "Qop": qop,
                        "Response": response,
                    },
                },
            }
        ]
        _, _, raw = await self._request("POST", "cmd=Login", json.dumps(body).encode())
        self._cipher = cipher
        res = self._decode(raw)
        if res[0].get("code") != 0:
            self._cipher = None
            raise RuntimeError(f"Reolink digest login failed: {res[0].get('error')}")
        token = res[0]["value"]["Token"]
        self._token = token["name"]
        basic = int(token.get("checkBasic", 0))
        total = int(token.get("countTotal", 32))
        self._counts = {i: basic for i in range(_FIRST_COMMAND_SLOT, max(total, 4))}
        self.secure = True
        self.logger.debug("Reolink %s: digest login, encrypted API", self.host)

    # -- requests --------------------------------------------------------------------

    def _query(self, cmd: Optional[str], extra: str = "") -> str:
        if not self.secure:
            parts = [f"token={self._token}"]
            if cmd:
                parts.append(f"cmd={cmd}")
            if extra:
                parts.append(extra)
            return "&".join(parts)
        slot = random.choice(list(self._counts))
        self._counts[slot] += 1
        plain = f"countId={slot}&checkNum={self._counts[slot]}"
        if cmd:
            plain += f"&cmd={cmd}"
        if extra:
            plain += f"&{extra}"
        assert self._cipher is not None
        return f"token={self._token}&encrypt={self._cipher.encrypt(plain)}"

    async def call(self, cmds: list[dict[str, Any]]) -> list:
        """Send one or more commands; logs in (again) as needed. Returns the reply list."""
        for attempt in (0, 1):
            if self._token is None:
                await self._login()
            body = json.dumps(
                [{"action": 0, **c} for c in cmds]
            )  # action is required by the encrypted API
            data = (
                self._cipher.encrypt(body).encode()
                if self.secure and self._cipher
                else body.encode()
            )
            name = cmds[0]["cmd"] if len(cmds) == 1 else None
            _, _, raw = await self._request("POST", self._query(name), data)
            res = self._decode(raw)
            if attempt == 0 and any(
                r.get("code") != 0
                and r.get("error", {}).get("rspCode") in STALE_TOKEN_CODES
                for r in res
            ):
                self._token = None
                continue
            return res
        return res

    async def call_one(self, cmd: str, param: Optional[dict] = None) -> dict:
        res = await self.call([{"cmd": cmd, "param": param or {}}])
        return res[0]

    async def snapshot(self, snap_type: str = "main") -> bytes:
        """A JPEG from the camera (``main``, ``sub`` or ``ext`` stream)."""
        for attempt in (0, 1):
            if self._token is None:
                await self._login()
            query = self._query("Snap", f"channel={self.channel}&snapType={snap_type}")
            if not self.secure:
                query += "&rs=unificamproxy"
            status, headers, raw = await self._request("GET", query, None)
            if status == 200 and raw[:2] == b"\xff\xd8":
                return raw
            # a JSON error instead of an image: usually an expired token
            try:
                res = self._decode(raw)
                code = res[0].get("error", {}).get("rspCode")
            except Exception:  # noqa: BLE001
                code = None
            if attempt == 0 and code in STALE_TOKEN_CODES:
                self._token = None
                continue
            raise RuntimeError(f"Reolink snapshot failed: status {status}, {raw[:120]!r}")
        raise RuntimeError("unreachable")

    async def logout(self) -> None:
        if self._token is None:
            return
        try:
            await self.call([{"cmd": "Logout", "param": {}}])
        except Exception:  # noqa: BLE001
            pass
        self._token = None
        self._cipher = None
