"""Security properties, not a mirror of database implementation."""

import tempfile
import unittest
from pathlib import Path

from internet.pairing import Pairing, Rejected


class PairingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "devices.sqlite3"
        self.now = 1000.0
        self.store = Pairing(self.path, clock=lambda: self.now)
        self.pc = self.store.register("pc")
        self.headset = self.store.register("headset")

    def tearDown(self):
        self.store.close()
        self.directory.cleanup()

    def claim(self):
        code = self.store.create_code(self.pc["device"])["code"]
        return self.store.claim(self.headset["device"], code)

    def test_claim_needs_pc_confirmation_and_matching_check(self):
        request = self.claim()
        self.assertFalse(self.store.trusted(self.pc["device"], self.headset["device"]))
        shown = self.store.requests(self.pc["device"])
        self.assertEqual(shown[0]["check"], request["check"])
        self.store.confirm(self.pc["device"], request["request"], True)
        self.assertTrue(self.store.trusted(self.pc["device"], self.headset["device"]))

    def test_code_single_use(self):
        code = self.store.create_code(self.pc["device"])["code"]
        self.store.claim(self.headset["device"], code)
        with self.assertRaises(Rejected):
            self.store.claim(self.headset["device"], code)

    def test_code_expiry_and_rotation(self):
        old = self.store.create_code(self.pc["device"])["code"]
        self.now += 121
        with self.assertRaises(Rejected):
            self.store.claim(self.headset["device"], old)
        old = self.store.create_code(self.pc["device"])["code"]
        self.store.create_code(self.pc["device"])
        with self.assertRaises(Rejected):
            self.store.claim(self.headset["device"], old)

    def test_other_pc_cannot_confirm(self):
        request = self.claim()
        other = self.store.register("pc")
        with self.assertRaises(Rejected):
            self.store.confirm(other["device"], request["request"], True)
        self.store.confirm(self.pc["device"], request["request"], True)

    def test_pending_confirmation_expires(self):
        request = self.claim()
        self.now += 121
        with self.assertRaises(Rejected):
            self.store.confirm(self.pc["device"], request["request"], True)

    def test_headset_cannot_generate_codes(self):
        with self.assertRaises(Rejected):
            self.store.create_code(self.headset["device"])

    def test_tokens_verified_and_not_stored_raw(self):
        self.assertEqual(self.store.authenticate(self.pc["device"], self.pc["token"]), "pc")
        with self.assertRaises(Rejected):
            self.store.authenticate(self.pc["device"], "wrong" * 10)
        for credential in (self.pc, self.headset):
            self.assertNotIn(credential["token"].encode(), self.path.read_bytes())

    def test_bound_devices_persist_but_pending_codes_do_not(self):
        request = self.claim()
        self.store.confirm(self.pc["device"], request["request"], True)
        code = self.store.create_code(self.pc["device"])["code"]
        self.store.close()
        self.store = Pairing(self.path, clock=lambda: self.now)
        self.assertEqual(self.store.devices(self.headset["device"], "headset"), [self.pc["device"]])
        with self.assertRaises(Rejected):
            self.store.claim(self.headset["device"], code)

    def test_either_endpoint_can_revoke(self):
        request = self.claim()
        self.store.confirm(self.pc["device"], request["request"], True)
        self.store.revoke(self.headset["device"], self.pc["device"], "headset")
        self.assertFalse(self.store.trusted(self.pc["device"], self.headset["device"]))
        self.assertEqual(self.store.devices(self.pc["device"], "pc"), [])

    def test_wrong_codes_throttled(self):
        for _ in range(5):
            with self.assertRaises(Rejected):
                self.store.claim(self.headset["device"], "invalid")
        with self.assertRaisesRegex(Rejected, "rate_limited"):
            self.claim()

    def test_bad_logins_do_not_exhaust_valid_device_login_budget(self):
        for _ in range(125):
            with self.assertRaises(Rejected):
                self.store.authenticate(self.pc["device"], "incorrect" * 5)
        self.assertEqual(self.store.authenticate(self.pc["device"], self.pc["token"]), "pc")

    def test_reject_and_replay_cannot_grant_access(self):
        request = self.claim()
        self.store.confirm(self.pc["device"], request["request"], False)
        with self.assertRaises(Rejected):
            self.store.confirm(self.pc["device"], request["request"], True)
        self.assertFalse(self.store.trusted(self.pc["device"], self.headset["device"]))


if __name__ == "__main__":
    unittest.main()
