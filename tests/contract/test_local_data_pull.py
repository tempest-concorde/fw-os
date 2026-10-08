"""Contract test (T014): /data/aircraft.json per fw-gsd contracts/local-data-pull.md.

Stdlib-only (unittest) so CI needs no pytest. Target readsb HTTP base URL from
env FW_ADSB_READSB_URL (default http://localhost:8080). Assertions are
contract-only: additive/optional fields are tolerated.
"""

import json
import os
import re
import time
import unittest
import urllib.error
import urllib.request

BASE_URL = os.environ.get("FW_ADSB_READSB_URL", "http://localhost:8080").rstrip("/")

HEX_RE = re.compile(r"^[0-9a-f]{6}$")

# Embedded sample containing fields beyond the contract minimum; the contract
# guarantees additive-only evolution, so unknown keys MUST be tolerated.
SAMPLE_WITH_EXTRA_FIELD = {
    "now": 1761609614.9,
    "messages": 39112,
    "aircraft": [
        {
            "hex": "a6f2b0",
            "flight": "AAL1258 ",
            "alt_baro": 32000,
            "seen": 0.8,
            "messages": 512,
            "some_future_field": {"nested": [1, 2, 3]},
        }
    ],
}


def fetch_aircraft():
    req = urllib.request.Request(BASE_URL + "/data/aircraft.json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        status = resp.getcode()
        body = resp.read()
    return status, body


def validate_aircraft_snapshot(case, doc):
    """Shared contract assertions for any aircraft.json-shaped document."""
    case.assertIsInstance(doc, dict, "top-level JSON object")
    case.assertIn("now", doc)
    case.assertIsInstance(doc["now"], (int, float), "now is epoch seconds")
    case.assertIn("messages", doc)
    case.assertIsInstance(doc["messages"], int, "messages is an int")
    case.assertGreaterEqual(doc["messages"], 0)
    case.assertIn("aircraft", doc)
    case.assertIsInstance(doc["aircraft"], list, "aircraft is a list (may be empty)")
    for ac in doc["aircraft"]:
        assert_aircraft_entry(case, ac)


def assert_aircraft_entry(case, ac):
    case.assertIsInstance(ac, dict)
    case.assertIn("hex", ac, "hex is the primary identity")
    case.assertRegex(ac["hex"], HEX_RE, "hex is 6 lowercase hex chars")
    if "alt_baro" in ac:
        if isinstance(ac["alt_baro"], str):
            case.assertEqual(ac["alt_baro"], "ground")
        else:
            case.assertIsInstance(ac["alt_baro"], int)
    if "flight" in ac:
        case.assertIsInstance(ac["flight"], str)
    if "messages" in ac:
        case.assertIsInstance(ac["messages"], int)
        case.assertGreaterEqual(ac["messages"], 0)
    # Unknown/extra fields are fine by construction (no exhaustive key check).


# Live-fetch cases require a running readsb HTTP endpoint. In the offline CI
# tier (recorded-replay) no server is up yet — FW_ADSB_READSB_URL stays unset
# and these cases skip; they run in the integration/UAT tiers instead.
LIVE_URL_SET = bool(os.environ.get("FW_ADSB_READSB_URL"))


class TestLocalDataPullContract(unittest.TestCase):
    @unittest.skipUnless(LIVE_URL_SET, "no live readsb endpoint configured (offline CI tier)")
    def test_aircraft_json_contract(self):
        status, body = fetch_aircraft()
        self.assertEqual(200, status, "GET /data/aircraft.json returns 200")
        doc = json.loads(body)
        validate_aircraft_snapshot(self, doc)
        if doc["aircraft"]:
            staleness = abs(time.time() - float(doc["now"]))
            self.assertLessEqual(
                staleness, 10, "now within 10s of wall clock when aircraft present"
            )

    def test_additive_field_tolerance(self):
        """Extra fields in aircraft entries MUST be tolerated (contract promise)."""
        validate_aircraft_snapshot(self, SAMPLE_WITH_EXTRA_FIELD)

    def test_alt_baro_ground_string_accepted(self):
        doc = {
            "now": time.time(),
            "messages": 1,
            "aircraft": [{"hex": "abc123", "alt_baro": "ground"}],
        }
        validate_aircraft_snapshot(self, doc)


if __name__ == "__main__":
    unittest.main()
