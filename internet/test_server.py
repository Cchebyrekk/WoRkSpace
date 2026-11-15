import asyncio
import json
import ssl
import tempfile
import os
import unittest
from pathlib import Path
from unittest.mock import patch

from internet.pairing import Pairing
from internet.server import Gateway

TLS_DIRECTORY = Path(__file__).resolve().parent.parent / "build/internet_test_tls"


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = Pairing(Path(self.directory.name) / "devices.sqlite3")
        self.pc = self.store.register("pc")
        self.headset = self.store.register("headset")
        self.gateway = Gateway(self.store, self.pc["device"], mode=lambda: 3)
        self.server = await self.gateway.listen("127.0.0.1", 0, TLS_DIRECTORY / "server.crt", TLS_DIRECTORY / "server.key")
        self.port = self.server.sockets[0].getsockname()[1]
        self.tls = ssl.create_default_context(cafile=str(TLS_DIRECTORY / "server.crt"))
        self.clients = []

    async def asyncTearDown(self):
        for writer in self.clients:
            writer.close()
            try:
                await writer.wait_closed()
            except (OSError, ssl.SSLError):
                pass
        self.server.close()
        await self.server.wait_closed()
        for tasks in tuple(self.gateway.active.values()):
            for task in tuple(tasks):
                task.cancel()
        await asyncio.sleep(0.05)
        self.store.close()
        self.directory.cleanup()

    async def connect(self):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port, ssl=self.tls, server_hostname="localhost")
        self.clients.append(writer)
        return reader, writer

    async def request(self, operation, **extra):
        reader, writer = await self.connect()
        request = {"v": 1, "op": operation, "device": self.headset["device"], "token": self.headset["token"], **extra}
        writer.write(json.dumps(request).encode() + b"\n")
        await writer.drain()
        reply = json.loads(await asyncio.wait_for(reader.readline(), 2))
        return reply, reader, writer

    def pair(self):
        code = self.gateway.create_code()["code"]
        request = self.store.claim(self.headset["device"], code)
        self.gateway.confirm(request["request"], True)

    async def test_registration_cannot_create_pc_owner(self):
        reply, _, _ = await self.request("register", role="pc")
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["role"], "headset")

    async def test_untrusted_and_invalid_token_cannot_open_tunnel(self):
        reply, _, _ = await self.request("tunnel", port=47802)
        self.assertEqual(reply["error"], "forbidden")
        reply, _, _ = await self.request("status", token="wrong" * 10)
        self.assertEqual(reply["error"], "unauthorized")

    async def test_status_only_discloses_mode_to_bound_device(self):
        reply, _, _ = await self.request("status")
        self.assertEqual(reply["mode"], -1)
        self.pair()
        reply, _, _ = await self.request("status")
        self.assertEqual(reply["mode"], 3)

    async def test_disallow_arbitrary_ports_and_destination_host(self):
        self.pair()
        reply, _, _ = await self.request("tunnel", port=22, host="invalid.example")
        self.assertEqual(reply["error"], "forbidden_port")
        reply, _, _ = await self.request("tunnel", port=True)
        self.assertEqual(reply["error"], "forbidden_port")

    async def test_binary_roundtrip_and_revocation_closes_existing_stream(self):
        self.pair()

        async def echo(reader, writer):
            try:
                while data := await reader.read(65536):
                    writer.write(data)
                    await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        backend = await asyncio.start_server(echo, "127.0.0.1", 0)
        port = backend.sockets[0].getsockname()[1]
        try:
            with patch("internet.server.ALLOWED_PORTS", frozenset({port})):
                reply, reader, writer = await self.request("tunnel", port=port)
                self.assertTrue(reply["ok"])
                payload = bytes(range(256)) * 1024
                writer.write(payload)
                await writer.drain()
                self.assertEqual(await asyncio.wait_for(reader.readexactly(len(payload)), 3), payload)
                self.gateway.revoke(self.headset["device"])
                self.assertEqual(await asyncio.wait_for(reader.read(1), 2), b"")
                reply, _, _ = await self.request("tunnel", port=port)
                self.assertEqual(reply["error"], "forbidden")
        finally:
            backend.close()
            await backend.wait_closed()

    async def test_untrusted_certificate_is_rejected(self):
        context = ssl.create_default_context()
        with self.assertRaises(ssl.SSLCertVerificationError):
            await asyncio.open_connection("127.0.0.1", self.port, ssl=context, server_hostname="localhost")

    async def test_malformed_device_and_large_request_do_not_crash_gateway(self):
        reply, _, _ = await self.request("status", device={})
        self.assertEqual(reply["error"], "unauthorized")
        reader, writer = await self.connect()
        writer.write(b"x" * 5000 + b"\n")
        await writer.drain()
        reply = json.loads(await asyncio.wait_for(reader.readline(), 2))
        self.assertEqual(reply["error"], "invalid_request")
        reply, _, _ = await self.request("status")
        self.assertTrue(reply["ok"])

    @unittest.skipUnless(os.name == "nt", "Godot integration uses the installed Windows editor")
    async def test_actual_godot_reports_tls_identity_failure(self):
        root = Path(__file__).resolve().parent.parent
        configuration = {"profile": {"host": "127.0.0.1", "port": self.port,
                                     "certificate": (TLS_DIRECTORY / "server.crt").read_text()},
                         "identity": self.headset, "service_port": 0, "expect_error": "TLS_ERROR"}
        temporary = Path(self.directory.name) / "client.json"
        temporary.write_text(json.dumps(configuration), encoding="utf-8")
        process = await asyncio.create_subprocess_exec(
            r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe",
            "--headless", "--xr-mode", "off", "--path", str(root),
            "-s", "tests/internet_client_probe.gd", "--", str(temporary),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            output, errors = await asyncio.wait_for(process.communicate(), 12)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            self.fail("Godot TLS rejection probe timed out")
        self.assertEqual(process.returncode, 0, (output + errors).decode(errors="replace"))
        self.assertIn(b"InternetClientProbe: PASSED rejection", output)

    @unittest.skipUnless(os.name == "nt", "Godot integration uses the installed Windows editor")
    async def test_actual_godot_client_tls_and_binary_framing(self):
        self.pair()

        async def echo(reader, writer):
            try:
                while data := await reader.read(65536):
                    writer.write(data)
                    await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        backend = await asyncio.start_server(echo, "127.0.0.1", 0)
        service = backend.sockets[0].getsockname()[1]
        root = Path(__file__).resolve().parent.parent
        configuration = {"profile": {"host": "127.0.0.1", "port": self.port,
                                     "certificate": (TLS_DIRECTORY / "server.crt").read_text()},
                         "identity": self.headset, "service_port": service}
        temporary = Path(self.directory.name) / "client.json"
        temporary.write_text(json.dumps(configuration), encoding="utf-8")
        try:
            with patch("internet.server.ALLOWED_PORTS", frozenset({service})):
                process = await asyncio.create_subprocess_exec(
                    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe",
                    "--headless", "--xr-mode", "off", "--path", str(root),
                    "-s", "tests/internet_client_probe.gd", "--", str(temporary),
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                try:
                    output, errors = await asyncio.wait_for(process.communicate(), 12)
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()
                    self.fail("Godot TLS probe timed out")
                self.assertEqual(process.returncode, 0, (output + errors).decode(errors="replace"))
                self.assertIn(b"InternetClientProbe: PASSED", output)
        finally:
            backend.close()
            await backend.wait_closed()


if __name__ == "__main__":
    unittest.main()
