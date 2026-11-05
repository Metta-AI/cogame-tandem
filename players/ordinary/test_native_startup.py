"""Run the ordinary CLI through real readiness HTTP, start HTTP and WebSocket registration."""

import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Event, Thread


def read_frame(stream):
    header = stream.read(2)
    if len(header) != 2:
        raise RuntimeError("Missing WebSocket frame")
    length = header[1] & 127
    if length == 126:
        length = struct.unpack("!H", stream.read(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", stream.read(8))[0]
    if length > 4096 or not header[1] & 128:
        raise RuntimeError("Invalid fixture client frame")
    mask = stream.read(4)
    data = stream.read(length)
    if len(data) != length:
        raise RuntimeError("Truncated WebSocket frame")
    return header[0] & 15, bytes(x ^ mask[i % 4] for i, x in enumerate(data))


class NativeStartupSystemTest(unittest.TestCase):
    def run_case(self, kind):
        allowed, attempted, connected = Event(), Event(), Event()
        registrations = []

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                if self.path == "/start":
                    attempted.set()
                    self.send_response(
                        401 if kind == "denied" else 200 if allowed.is_set() else 503
                    )
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self.connection.settimeout(3)
                connected.set()
                key = self.headers["Sec-WebSocket-Key"]
                accept = base64.b64encode(
                    hashlib.sha1(
                        (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                    ).digest()
                ).decode()
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                self.end_headers()
                opcode, data = read_frame(self.rfile)
                if (
                    opcode != 2
                    or data[0] != 0x81
                    or int.from_bytes(data[1:3], "little") != len(data) - 3
                ):
                    raise RuntimeError("Missing ordinary Sprite registration")
                registrations.append(json.loads(data[3:]))
                final = json.dumps(
                    {
                        "type": "final",
                        "scores": [0.5, 0.5],
                        "reason": "synthetic-startup-fixture",
                    }
                ).encode()
                self.wfile.write(bytes([0x81, len(final)]) + final)
                self.wfile.flush()
                opcode, _ = read_frame(self.rfile)
                if opcode != 8:
                    raise RuntimeError("Missing WebSocket close")
                self.wfile.write(b"\x88\x00")
                self.wfile.flush()
                self.close_connection = True

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with socket.socket() as port_probe:
            port_probe.bind(("127.0.0.1", 0))
            port = port_probe.getsockname()[1]
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith(("TANDEM_", "COWORLD_", "PLAYER_"))
        }
        env.update(
            COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{server.server_port}/player?slot=0&token=fixture",
            NO_PROXY="127.0.0.1,localhost",
            no_proxy="127.0.0.1,localhost",
        )
        if kind != "legacy":
            env.update(
                COWORLD_PLAYER_START_URL=f"http://127.0.0.1:{server.server_port}/start",
                TANDEM_STARTUP_PORT=str(port),
                TANDEM_STARTUP_WAIT_SECONDS="0.25" if kind == "timeout" else "3",
            )
        child = subprocess.Popen(
            [sys.executable, "player.py"],
            cwd=Path(__file__).resolve().parent,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            if kind == "warm":
                deadline = time.monotonic() + 3
                while True:
                    try:
                        with urllib.request.urlopen(
                            f"http://127.0.0.1:{port}/healthz", timeout=0.2
                        ) as response:
                            self.assertEqual(response.status, 200)
                        break
                    except urllib.error.URLError:
                        if time.monotonic() >= deadline or child.poll() is not None:
                            self.fail("Ordinary CLI did not report readiness")
                        time.sleep(0.01)
                self.assertTrue(attempted.wait(1), "Player did not poll its start gate")
                self.assertFalse(
                    connected.is_set(), "Player connected before start permission"
                )
                allowed.set()
            stdout, stderr = child.communicate(timeout=5)
            if kind in {"legacy", "warm"}:
                self.assertEqual(child.returncode, 0, stderr)
                self.assertTrue(connected.is_set())
                self.assertEqual(len(registrations), 1)
                self.assertEqual(
                    registrations[0],
                    {"type": "register", "scripted": None, "policy": "heuristic"},
                )
                self.assertIn("ordinary player finished", stdout)
            else:
                self.assertNotEqual(child.returncode, 0)
                self.assertIn(
                    "HTTPError" if kind == "denied" else "TimeoutError", stderr
                )
                self.assertFalse(connected.is_set())
            with socket.socket() as probe:
                self.assertNotEqual(
                    probe.connect_ex(("127.0.0.1", port)),
                    0,
                    "Readiness listener leaked",
                )
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=3)
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_ready_before_game_then_original_socket(self):
        self.run_case("warm")

    def test_legacy_connection_without_startup(self):
        self.run_case("legacy")

    def test_start_gate_denial_refuses_connection(self):
        self.run_case("denied")

    def test_start_gate_timeout_is_bounded_and_cleans_up(self):
        self.run_case("timeout")


if __name__ == "__main__":
    unittest.main()
