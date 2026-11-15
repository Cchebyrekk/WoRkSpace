"""Persistent pairing state. No names, network identifiers or raw secrets stored."""

from __future__ import annotations

import hashlib
import hmac
import re
import secrets
import sqlite3
import time
from collections import deque
from pathlib import Path


class Rejected(Exception):
    """A deliberately non-identifying error safe to show to a client."""


class Pairing:
    CODE_SECONDS = 120
    CONFIRM_SECONDS = 120
    MAX_DEVICES = 10000

    def __init__(self, path: str | Path, *, clock=time.time):
        self.clock = clock
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS devices(
                id TEXT PRIMARY KEY, role TEXT NOT NULL, digest TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS pairs(
                pc TEXT REFERENCES devices(id) ON DELETE CASCADE,
                headset TEXT REFERENCES devices(id) ON DELETE CASCADE,
                PRIMARY KEY(pc,headset));
        """)
        # Codes and unconfirmed requests intentionally do not survive a restart.
        self.code_key = secrets.token_bytes(32)
        self.codes: dict[str, tuple[str, float]] = {}
        self.pending: dict[str, tuple[str, str, float, str]] = {}
        self.budgets: dict[str, deque] = {}

    def close(self):
        self.db.close()

    def _limit(self, key: str, limit: int, seconds: int = 60):
        now = self.clock()
        # Bound memory even when many authenticated clients send requests.
        for old in list(self.budgets):
            if not self.budgets[old] or self.budgets[old][-1] <= now - seconds:
                del self.budgets[old]
        budget = self.budgets.setdefault(key, deque())
        while budget and budget[0] <= now - seconds:
            budget.popleft()
        if len(budget) >= limit:
            raise Rejected("rate_limited")
        budget.append(now)

    def _prune(self):
        now = self.clock()
        self.codes = {k: v for k, v in self.codes.items() if v[1] > now}
        self.pending = {k: v for k, v in self.pending.items() if v[2] > now}

    def register(self, role: str) -> dict:
        if role not in ("pc", "headset"):
            raise Rejected("invalid_role")
        self._limit("register", 10)
        if self.db.execute("SELECT count(*) FROM devices").fetchone()[0] >= self.MAX_DEVICES:
            raise Rejected("capacity")
        device = secrets.token_hex(16)
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode("ascii")).hexdigest()
        with self.db:
            self.db.execute("INSERT INTO devices VALUES(?,?,?)", (device, role, digest))
        return {"device": device, "token": token, "role": role}

    def authenticate(self, device: str, token: str) -> str:
        if not isinstance(device, str) or not re.fullmatch(r"[0-9a-f]{32}", device):
            self._limit("failed-authentication", 60)
            raise Rejected("unauthorized")
        if not isinstance(token, str) or not 32 <= len(token) <= 128:
            self._limit("failed-authentication", 60)
            raise Rejected("unauthorized")
        row = self.db.execute("SELECT role,digest FROM devices WHERE id=?", (device,)).fetchone()
        digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
        if row is None or not hmac.compare_digest(row[1], digest):
            self._limit("failed-authentication", 60)
            raise Rejected("unauthorized")
        self._limit("authentication:" + device, 120)
        return row[0]

    def _role(self, device: str, role: str):
        row = self.db.execute("SELECT role FROM devices WHERE id=?", (device,)).fetchone()
        if row is None or row[0] != role:
            raise Rejected("forbidden")

    def _code_digest(self, code: str) -> str:
        return hmac.new(self.code_key, code.encode("ascii"), "sha256").hexdigest()

    def create_code(self, pc: str) -> dict:
        self._role(pc, "pc")
        self._limit("codes:" + pc, 5)
        self._prune()
        self.codes = {k: v for k, v in self.codes.items() if v[0] != pc}
        self.pending = {k: v for k, v in self.pending.items() if v[0] != pc}
        for _ in range(20):
            code = f"{secrets.randbelow(100_000_000):08d}"
            digest = self._code_digest(code)
            if digest not in self.codes:
                self.codes[digest] = (pc, self.clock() + self.CODE_SECONDS)
                return {"code": code, "expires_in": self.CODE_SECONDS}
        raise Rejected("capacity")

    def claim(self, headset: str, code: str) -> dict:
        self._role(headset, "headset")
        self._limit("claim:" + headset, 5)
        self._limit("claims_global", 30)
        self._prune()
        if not isinstance(code, str) or not re.fullmatch(r"[0-9]{8}", code):
            raise Rejected("invalid_code")
        found = self.codes.pop(self._code_digest(code), None)
        if found is None:
            raise Rejected("invalid_code")
        pc, _ = found
        request = secrets.token_hex(16)
        # Matching phrase shown at both ends; the PC must explicitly approve.
        check = secrets.token_hex(3).upper()
        self.pending[request] = (pc, headset, self.clock() + self.CONFIRM_SECONDS, check)
        return {"request": request, "pc": pc, "check": check,
                "expires_in": self.CONFIRM_SECONDS}

    def requests(self, pc: str) -> list[dict]:
        self._role(pc, "pc")
        self._prune()
        return [{"request": key, "device": item[1], "check": item[3],
                 "expires_in": max(0, int(item[2] - self.clock()))}
                for key, item in self.pending.items() if item[0] == pc]

    def confirm(self, pc: str, request: str, approve: bool):
        self._role(pc, "pc")
        self._prune()
        item = self.pending.get(request)
        if item is None or item[0] != pc:
            raise Rejected("not_found")
        del self.pending[request]
        if approve:
            with self.db:
                self.db.execute("INSERT OR IGNORE INTO pairs VALUES(?,?)", (pc, item[1]))

    def trusted(self, pc: str, headset: str) -> bool:
        return self.db.execute("SELECT 1 FROM pairs WHERE pc=? AND headset=?", (pc, headset)).fetchone() is not None

    def devices(self, owner: str, role: str) -> list[str]:
        self._role(owner, role)
        if role == "pc":
            rows = self.db.execute("SELECT headset FROM pairs WHERE pc=?", (owner,))
        else:
            rows = self.db.execute("SELECT pc FROM pairs WHERE headset=?", (owner,))
        return [row[0] for row in rows]

    def revoke(self, owner: str, peer: str, role: str):
        self._role(owner, role)
        pc, headset = (owner, peer) if role == "pc" else (peer, owner)
        with self.db:
            self.db.execute("DELETE FROM pairs WHERE pc=? AND headset=?", (pc, headset))
        self.pending = {k: v for k, v in self.pending.items() if not (v[0] == pc and v[1] == headset)}
