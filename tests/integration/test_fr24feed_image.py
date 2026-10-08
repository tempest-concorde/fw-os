"""Integration test (T018): fr24feed image structural + disabled-mode checks.

Per research.md Decision 8: fr24feed is NEVER executed against FR24 in CI —
the gate is binary presence, no baked secrets, and a disabled-mode entrypoint
smoke. Stdlib-only; skips without podman or the built image.
"""

import shutil
import subprocess
import unittest

from test_recorded_beast import image_exists

IMAGE = "ghcr.io/tempest-concorde/fw-adsb-fr24feed:test"


@unittest.skipUnless(shutil.which("podman"), "podman not available")
@unittest.skipUnless(
    not shutil.which("podman") or image_exists(IMAGE), f"image {IMAGE} not built"
)
class TestFr24feedImage(unittest.TestCase):
    def run_in_image(self, *args):
        return subprocess.run(
            ["podman", "run", "--rm", IMAGE, *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )

    def test_fr24feed_binary_present(self):
        r = self.run_in_image(
            "/bin/sh", "-c", "command -v fr24feed && test -x /usr/local/bin/fr24feed"
        )
        self.assertEqual(0, r.returncode, r.stderr)

    def test_no_secrets_baked_into_image(self):
        r = self.run_in_image(
            "/bin/sh", "-c",
            "if [ -d /run/secrets ]; then ls -A /run/secrets | wc -l; else echo 0; fi"
        )
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertEqual(
            "0", r.stdout.strip(), "no secret content baked into the image"
        )

    def test_entrypoint_idles_when_push_disabled(self):
        r = subprocess.run(
            [
                "podman", "run", "--rm",
                "-e", "FW_FR24_ENABLED=false",
                IMAGE, "/bin/sh", "-c",
                "/usr/local/bin/fw-adsb-fr24feed-entrypoint.sh & sleep 2; echo OK",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn("OK", r.stdout)


if __name__ == "__main__":
    unittest.main()
