"""Integration test (T008): replay tests/fixtures/sample.beast through readsb.

Launches the built readsb image with READSB_IFILE (offline replay) via podman,
waits for /data/aircraft.json, and asserts the fixture's known decode
(hex "abc123", flight "TEST01*" — see tests/fixtures/README.md). Stdlib-only;
skips cleanly when podman or the image is unavailable.
"""

import json
import os
import shutil
import subprocess
import time
import unittest
import urllib.request

IMAGE = "ghcr.io/tempest-concorde/fw-adsb-readsb:test"
FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures")
HTTP_PORT = 18080
BASE_URL = f"http://localhost:{HTTP_PORT}"


def image_exists(image):
    return (
        subprocess.run(
            ["podman", "image", "inspect", image],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
        == 0
    )


def wait_for_aircraft_json(timeout=60, require_aircraft=True):
    """Poll /data/aircraft.json until HTTP 200 — and, with require_aircraft,
    until at least one aircraft is decoded. The replay feeder paces frames at
    1/s, so the first 200 usually still shows an empty aircraft array."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(
                BASE_URL + "/data/aircraft.json", timeout=5
            ) as resp:
                if resp.getcode() == 200:
                    doc = json.loads(resp.read())
                    if not require_aircraft or doc.get("aircraft"):
                        return doc
        except (OSError, ValueError):
            pass
        time.sleep(1)
    raise AssertionError("timed out waiting for /data/aircraft.json")


@unittest.skipUnless(shutil.which("podman"), "podman not available")
@unittest.skipUnless(
    not shutil.which("podman") or image_exists(IMAGE), f"image {IMAGE} not built"
)
class TestRecordedBeastReplay(unittest.TestCase):
    container_id = None

    @classmethod
    def setUpClass(cls):
        out = subprocess.run(
            [
                "podman", "run", "-d", "--rm",
                "-e", "READSB_IFILE=/fixture/sample.beast",
                "-v", f"{os.path.abspath(FIXTURES)}:/fixture:ro,Z",
                "-p", f"{HTTP_PORT}:8080",
                IMAGE,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        cls.container_id = out.stdout.strip()

    @classmethod
    def tearDownClass(cls):
        if cls.container_id:
            subprocess.run(
                ["podman", "stop", cls.container_id],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

    def test_replay_yields_fixture_aircraft(self):
        doc = wait_for_aircraft_json()
        self.assertIsInstance(doc.get("aircraft"), list)
        hexes = [ac.get("hex") for ac in doc["aircraft"]]
        self.assertIn("abc123", hexes, "fixture aircraft hex abc123 decoded")
        flights = [ac.get("flight", "").strip() for ac in doc["aircraft"]]
        self.assertTrue(
            any(f.startswith("TEST01") for f in flights),
            f"fixture callsign TEST01 decoded (got {flights})",
        )
        self.assertGreater(doc.get("messages", 0), 0)
        staleness = abs(time.time() - float(doc["now"]))
        self.assertLessEqual(staleness, 10, "snapshot timestamp is fresh")


if __name__ == "__main__":
    unittest.main()
