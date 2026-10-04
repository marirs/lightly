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
        (self.root / "run_bounded.py").write_text((SOURCE.parent / "run_bounded.py").read_text())
        self.lock = self.root / "lock"
        self.wrapper = self.root / "heavy"
        self.wrapper.write_text(SOURCE.read_text().replace("/tmp/lightly-heavy.lock", str(self.lock)).replace("/tmp/lightly-heavy.log", str(self.root / "log")).replace("/tmp/lightly-heavy.reservation", str(self.root / "reservation")))
        for name in ("xcrun", "adb", "pkill"):
            stub = self.root / name
            stub.write_text("#!/bin/sh\nexit 0\n")
            stub.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.root) + ":" + os.environ["PATH"])
        self.env.pop("LIGHTLY_HEAVY_LOCK_HELD", None)
        self.env.pop("LIGHTLY_BOUNDED_JOB", None)

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

    def test_busy_caller_reserves_the_next_turn(self):
        # The 2026-10-04 starvation: R gets BUSY during a long job; when that job
        # ends, a chained job C asks at once. R, resubmitting a moment later,
        # must go first.
        def start(label, wait, seconds):
            return subprocess.Popen(["bash", str(self.wrapper), label, "sleep", str(seconds)],
                                    env=dict(self.env, LIGHTLY_HEAVY_WAIT_SECONDS=str(wait)))
        long_job = start("chain-1", 5, 3)
        time.sleep(0.5)
        self.assertEqual(start("reserver", 1, 0.1).wait(timeout=10), 75)
        self.assertEqual(long_job.wait(timeout=10), 0)
        chained = start("chain-2", 10, 0.1)
        time.sleep(1)
        resubmitted = start("reserver", 10, 0.1)
        self.assertEqual(resubmitted.wait(timeout=20), 0)
        self.assertEqual(chained.wait(timeout=20), 0)
        log = (self.root / "log").read_text()
        starts = [line.split("label=")[1].split()[0] for line in log.splitlines() if " START " in line]
        self.assertEqual(starts, ["chain-1", "reserver", "chain-2"])
        self.assertIn(" RESERVE ", log)
        self.assertFalse((self.root / "reservation").exists())

    def test_invalid_wait_rejected(self):
        self.assertEqual(self.run_job("bad", "true").returncode, 64)

if __name__ == "__main__":
    unittest.main()
