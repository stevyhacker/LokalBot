#!/usr/bin/env python3
"""Run the probe's bounded-capture contract without taking a screenshot."""

from pathlib import Path
import subprocess
import sys
import unittest


# Compiles a Swift script with xcrun. Build's unit-test job runs it on macOS;
# the CI helpers job on Linux skips it. That job runs the unit tests, the
# workday and the crash probe at the same time, and the compile alone passed
# 60 s there on 2026-11-18, so the limit allows for a loaded runner.
@unittest.skipUnless(sys.platform == "darwin", "needs Xcode")
class CotypingProbeContractTests(unittest.TestCase):
    def test_capture_is_region_bounded_and_dimension_checked(self):
        script = Path(__file__).resolve().parents[1] / "cotyping" / "cotyping-probe.swift"
        result = subprocess.run(
            ["/usr/bin/xcrun", "swift", str(script), "--self-test-capture-contract"],
            capture_output=True,
            text=True,
            timeout=300,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("capture contract passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
