"""TLS gateway hosted on the user's PC. Forwards only authenticated WoRkPlace ports."""

from __future__ import annotations

import argparse
import asyncio
import json
import ssl
from pathlib import Path

from internet.pairing import Pairing, Rejected

ALLOWED_PORTS = frozenset(range(47802, 47820)) | frozenset(range(47902, 47921))
MAX_REQUEST = 4096


async def response(writer, value):
    writer.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
    await asyncio.wait_for(writer.drain(), 5)


async def pump(reader, writer):
    while data := await reader.read(65536):
        writer.write(data)
        await asyncio.wait_for(writer.drain(), 10)


class Gateway:
    def __init__(self, store: Pairing, pc: str, *, mode=lambda: 1):
        self.store = store
        self.pc = pc
        self.mode = mode
        self.connections = 0
        self.active: dict[str, set[asyncio.Task]] = {}

    def create_code(self):
        """Local administration only, never callable through the public protocol."""
        return self.store.create_code(self.pc)

    def requests(self):
        return self.store.requests(self.pc)

    def confirm(self, request: str, approve: bool):
        self.store.confirm(self.pc, request, approve)

    def revoke(self, device: str):
        self.store.revoke(self.pc, device, "pc")
        # Revoke active video/control streams too, not just future logins.
        for task in tuple(self.active.get(device, ())):
            task.cancel()

    async def handle(self, reader, writer):
        local = None
        device = None
        task = asyncio.current_task()
        admitted = self.connections < 64
        try:
            if not admitted:
                return
            self.connections += 1
            line = await asyncio.wait_for(reader.readline(), 5)
            if len(line) > MAX_REQUEST or not line.endswith(b"\n"):
                raise Rejected("invalid_request")
            request = json.loads(line)
            if not isinstance(request, dict) or request.get("v") != 1:
                raise Rejected("incompatible_protocol")
            operation = request.get("op")
            if operation == "register":
                # PC ownership is established locally, never by a remote caller.
                await response(writer, {"ok": True, **self.store.register("headset")})
                return
            candidate = request.get("device")
            role = self.store.authenticate(candidate, request.get("token"))
            device = candidate
            if role != "headset":
                raise Rejected("forbidden")
            if operation == "claim":
                result = self.store.claim(device, request.get("code"))
                await response(writer, {"ok": True, **result})
                return
            if operation == "status":
                trusted = self.store.trusted(self.pc, device)
                await response(writer, {"ok": True, "trusted": trusted,
                                        "mode": self.mode() if trusted else -1})
                return
            if operation == "forget":
                self.revoke(device)
                await response(writer, {"ok": True})
                return
            if operation != "tunnel" or not self.store.trusted(self.pc, device):
                raise Rejected("forbidden")
            port = request.get("port")
            if type(port) is not int or port not in ALLOWED_PORTS:
                raise Rejected("forbidden_port")
            active = self.active.setdefault(device, set())
            if len(active) >= 24:
                raise Rejected("capacity")
            active.add(task)
            # No hostname or destination supplied by the peer is ever used here.
            upstream_reader, local = await asyncio.wait_for(
                asyncio.open_connection("127.0.0.1", port), 3)
            await response(writer, {"ok": True})
            workers = [asyncio.create_task(pump(reader, local)),
                       asyncio.create_task(pump(upstream_reader, writer))]
            try:
                done, _ = await asyncio.wait(workers, return_when=asyncio.FIRST_COMPLETED)
                for completed in done:
                    completed.result()
            finally:
                for worker in workers:
                    worker.cancel()
                await asyncio.gather(*workers, return_exceptions=True)
        except Rejected as error:
            try:
                await response(writer, {"ok": False, "error": str(error)})
            except (OSError, asyncio.TimeoutError):
                pass
        except (ValueError, UnicodeError, TypeError):
            try:
                await response(writer, {"ok": False, "error": "invalid_request"})
            except (OSError, asyncio.TimeoutError):
                pass
        except (OSError, asyncio.TimeoutError):
            # Do not return addresses, backend exception text or credentials.
            try:
                await response(writer, {"ok": False, "error": "unavailable"})
            except (OSError, asyncio.TimeoutError):
                pass
        finally:
            if admitted:
                self.connections -= 1
            if device in self.active:
                self.active[device].discard(task)
                if not self.active[device]:
                    del self.active[device]
            for connection in (local, writer):
                if connection is not None:
                    connection.close()
            for connection in (local, writer):
                if connection is not None:
                    try:
                        await asyncio.wait_for(connection.wait_closed(), 2)
                    except (OSError, asyncio.TimeoutError):
                        pass

    async def listen(self, address: str, port: int, certificate: Path, key: Path):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certificate, key)
        return await asyncio.start_server(self.handle, address, port, ssl=context,
                                          limit=MAX_REQUEST + 1,
                                          ssl_handshake_timeout=5,
                                          ssl_shutdown_timeout=2)


def load_pc(store: Pairing, directory: Path) -> str:
    # Local administration needs no persistent bearer token at all.
    owners = store.db.execute("SELECT id FROM devices WHERE role='pc'").fetchall()
    if len(owners) > 1:
        raise Rejected("invalid_owner")
    return owners[0][0] if owners else store.register("pc")["device"]


async def main(args):
    directory = Path(args.state)
    directory.mkdir(parents=True, exist_ok=True)
    store = Pairing(directory / "devices.sqlite3")
    pc = load_pc(store, directory)
    gateway = Gateway(store, pc)
    server = await gateway.listen(args.listen, args.port, Path(args.certificate), Path(args.key))
    print("Internet gateway listening (TLS); device pairing UI not connected yet.", flush=True)
    try:
        async with server:
            await server.serve_forever()
    finally:
        store.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="WoRkPlace PC internet gateway")
    parser.add_argument("--state", required=True)
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=47930)
    try:
        asyncio.run(main(parser.parse_args()))
    except KeyboardInterrupt:
        pass
