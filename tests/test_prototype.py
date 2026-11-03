"""Hardware-free tests for the Python prototype: config validation, persistence and the local HTTP API.

Run from the repo root: python -m unittest tests.test_prototype   (needs numpy and scikit-learn; macOS, for the IOKit bindings)
"""

import http.client
import json
import os
import stat
import tempfile
import threading
import time
import unittest
from pathlib import Path

from lidtap import server
from lidtap.app import App


class AppConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "data"
        self.app = App(self.dir)

    def tearDown(self):
        self.tmp.cleanup()

    def test_rejects_non_finite_and_out_of_range_numbers(self):
        for body in ({"k": "nan"}, {"k": float("inf")}, {"k": 1e9}, {"refractory": -1}):
            with self.assertRaises(ValueError):
                self.app.set_config(body)

    def test_actions_keep_only_zone_keys(self):
        self.app.set_config({"actions": {"z0": "echo hi", "../x": "rm -rf /", "noise": "x"}})
        self.assertEqual(self.app.cfg["actions"], {"z0": "echo hi"})

    def test_files_are_owner_only(self):
        self.app.set_config({"k": 7})
        mode = stat.S_IMODE(os.stat(self.dir / "config.json").st_mode)
        self.assertEqual(mode, 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.dir).st_mode), 0o700)

    def test_corrupt_files_are_moved_aside(self):
        (self.dir / "config.json").write_text("{broken")
        (self.dir / "dataset.json").write_text("[]")
        app = App(self.dir)
        self.assertEqual(app.cfg["k"], 6.0)
        self.assertEqual(app.samples, [])
        self.assertTrue(list(self.dir.glob("config.json.corrupt-*")))

    def test_noise_recording_ends_without_a_gui(self):
        self.app.negatives_start({"seconds": 1})
        self.app.neg_until = time.time() - 1  # time is up, nobody polled status()
        import numpy as np
        ev = {"id": 1, "t": 0.0, "wall": time.time(), "g": np.zeros((160, 3)), "a": np.zeros((160, 3)),
              "peak_g": 0.0, "peak_a": 0.0, "lid": None, "threshold": 1.0, "noise": 0.1, "gated": None}
        self.app.on_event(ev)
        self.assertEqual(self.app.mode, "idle")
        self.assertEqual(self.app.samples, [])


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.httpd = server.serve(App(Path(cls.tmp.name) / "data"), 0)
        cls.port = cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.tmp.cleanup()

    def request(self, method, path, body=None, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request(method, path, body=body, headers=headers or {})
        r = c.getresponse()
        data = r.read()
        c.close()
        return r, data

    def test_page_cannot_be_framed(self):
        r, _ = self.request("GET", "/")
        self.assertEqual(r.status, 200)
        self.assertEqual(r.getheader("X-Frame-Options"), "DENY")
        self.assertIn("frame-ancestors 'none'", r.getheader("Content-Security-Policy"))

    def test_foreign_host_is_refused(self):
        r, _ = self.request("GET", "/", headers={"Host": "attacker.example"})
        self.assertEqual(r.status, 403)

    def test_post_needs_the_token(self):
        r, _ = self.request("POST", "/api/stop", "{}", {"X-Token": "wrong"})
        self.assertEqual(r.status, 403)
        r, _ = self.request("POST", "/api/stop", "{}", {"X-Token": server.TOKEN})
        self.assertEqual(r.status, 200)

    def test_bad_bodies_are_400_not_crashes(self):
        for body in ("not json", "[1, 2]"):
            r, data = self.request("POST", "/api/stop", body, {"X-Token": server.TOKEN})
            self.assertEqual(r.status, 400, data)

    def test_static_paths_cannot_escape(self):
        r, _ = self.request("GET", "/static/../app.py")
        self.assertEqual(r.status, 404)

    def test_state_is_json(self):
        r, data = self.request("GET", "/api/state")
        self.assertEqual(r.status, 200)
        self.assertIn("status", json.loads(data))


if __name__ == "__main__":
    unittest.main()
