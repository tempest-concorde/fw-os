"""Integration test (T015): SBS (30003) and BEAST (30005) stream outputs.

Same fixture container as T008 (tests/fixtures/sample.beast replayed via
READSB_IFILE). Sockets are connected in setUpClass BEFORE the HTTP wait so the
initial replay burst is captured (VERIFY-on-hardware/CI: if readsb in --ifile
mode replays before listeners attach, this test needs a longer/looping fixture).
Stdlib-only; skips cleanly without podman or the built image.
"""

import os
import shutil
import socket
import subprocess
import threading
import time
import unittest

from test_recorded_beast import IMAGE, HTTP_PORT, FIXTURES, \
    image_exists, wait_for_aircraft_json

SBS_PORT = 13003
BEAST_PORT = 13005


@unittest.skipUnless(shutil.which("podman"), "podman not available")
@unittest.skipUnless(
    not shutil.which("podman") or image_exists(IMAGE), f"image {IMAGE} not built"
)
class TestStreams(unittest.TestCase):
    container_id = None

    @classmethod
    def setUpClass(cls):
        out = subprocess.run(
            [
                "podman", "run", "-d", "--rm",
                "-e", "READSB_IFILE=/fixture/sample.beast",
                "-v", f"{os.path.abspath(FIXTURES)}:/fixture:ro,Z",
                "-p", f"{HTTP_PORT}:8080",
                "-p", f"{SBS_PORT}:30003",
                "-p", f"{BEAST_PORT}:30005",
                IMAGE,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        cls.container_id = out.stdout.strip()
        wait_for_aircraft_json()

    @classmethod
    def tearDownClass(cls):
        if cls.container_id:
            subprocess.run(
                ["podman", "stop", cls.container_id],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

    def test_sbs_stream_emits_msg_lines(self):
        lines = []
        deadline = time.time() + 30

        def reader():
            with socket.create_connection(("127.0.0.1", SBS_PORT), timeout=10) as s:
                s.settimeout(5)
                with s.makefile("r", newline="\n") as f:
                    while time.time() < deadline:
                        try:
                            line = f.readline()
                        except socket.timeout:
                            continue
                        if not line:
                            break
                        lines.append(line.rstrip("\r\n"))

        t = threading.Thread(target=reader, daemon=True)
        t.start()
        t.join(timeout=45)
        self.assertTrue(
            any(line.startswith("MSG,") for line in lines),
            f"expected at least one SBS MSG line, got {lines[:10]}",
        )

    def test_beast_stream_emits_escaped_frames(self):
        deadline = time.time() + 30
        buf = b""
        with socket.create_connection(("127.0.0.1", BEAST_PORT), timeout=10) as s:
            s.settimeout(5)
            while time.time() < deadline and not buf:
                try:
                    chunk = s.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                buf += chunk
        self.assertTrue(buf, "no BEAST bytes received")
        self.assertEqual(
            buf[0], 0x1A, "first BEAST byte is the 0x1A escape marker"
        )


if __name__ == "__main__":
    unittest.main()
