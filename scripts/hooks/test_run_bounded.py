import sys
import time
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run_bounded import run

class BoundedTests(unittest.TestCase):
    def test_exit_status(self):
        self.assertEqual(run([sys.executable, "-c", "raise SystemExit(7)"], 2), 7)

    def test_timeout_stops_descendants(self):
        with tempfile.TemporaryDirectory(prefix="lightly-budget-test-") as d:
            marker = Path(d) / "unexpected"
            child = "import time,pathlib;time.sleep(1);pathlib.Path(" + repr(str(marker)) + ").touch()"
            parent = "import subprocess,sys,time;subprocess.Popen([sys.executable,'-c'," + repr(child) + "]);time.sleep(20)"
            start = time.monotonic()
            self.assertEqual(run([sys.executable, "-c", parent], .25), 124)
            self.assertLess(time.monotonic()-start, 3)
            time.sleep(1.1)
            self.assertFalse(marker.exists())

if __name__ == "__main__":
    unittest.main()
