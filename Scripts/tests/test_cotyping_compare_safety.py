"""The side-by-side autocomplete scripts must never stop or drive an app they don't own."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CotypingCompareSafetyTests(unittest.TestCase):
    def test_scripts_refuse_running_apps_and_touch_only_their_own_document(self):
        # The shell test puts stand-ins for pgrep, open, pkill, osascript, screencapture
        # and sleep first on PATH, so nothing is launched, quit or captured.
        done = subprocess.run(["/bin/bash", str(ROOT / "Scripts/tests/compare-cotyping-safety.sh")],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("Cotyping process-safety regressions passed.", done.stdout)


if __name__ == "__main__":
    unittest.main()
