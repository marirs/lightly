"""Exercise the wrapper with an isolated lock and inert device commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "heavy"

class HeavyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="lightly-heavy-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.lock = self.root / "lock"
        self.wrapper = self.root / "heavy"
        self.wrapper.write_text(SOURCE.read_text().replace("/tmp/lightly-heavy.lock", str(self.lock)).replace("/tmp/lightly-heavy.log", str(self.root / "log")))
        for name in ("xcrun", "adb", "pkill"):
            stub = self.root / name
            stub.write_text("#!/bin/sh\nexit 0\n")
            stub.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.root) + ":" + os.environ["PATH"])
        self.env.pop("LIGHTLY_HEAVY_LOCK_HELD", None)

    def run_job(self, wait, *command):
        return subprocess.run(["bash", str(self.wrapper), "test", *command], env=dict(self.env, LIGHTLY_HEAVY_WAIT_SECONDS=wait), capture_output=True, text=True, timeout=8)

    def test_command_status_propagates(self):
        self.assertEqual(self.run_job("1", "bash", "-c", "exit 7").returncode, 7)

    def test_busy_does_not_run_command(self):
        ready = self.root / "ready"
        marker = self.root / "must-not-run"
        holder = subprocess.Popen(["lockf", "-k", str(self.lock), "sh", "-c", 'touch "$1"; exec sleep 6', "hold", str(ready)])
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(ready.exists())
            result = self.run_job("1", "touch", str(marker))
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn(" BUSY ", (self.root / "log").read_text())
        finally:
            holder.terminate()
            holder.wait(timeout=8)

    def test_command_exit_75_is_not_logged_busy(self):
        result = self.run_job("1", "bash", "-c", "exit 75")
        self.assertEqual(result.returncode, 75)
        log = (self.root / "log").read_text()
        self.assertNotIn(" BUSY ", log)
        self.assertIn("status=75", log)

    def test_invalid_wait_rejected(self):
        self.assertEqual(self.run_job("bad", "true").returncode, 64)

if __name__ == "__main__":
    unittest.main()
