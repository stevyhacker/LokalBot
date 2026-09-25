#!/usr/bin/env python3
"""Run the probe's bounded-capture contract without taking a screenshot."""

from pathlib import Path
import subprocess
import unittest


class CotypingProbeContractTests(unittest.TestCase):
    def test_capture_is_region_bounded_and_dimension_checked(self):
        script = Path(__file__).resolve().parents[1] / "cotyping-probe.swift"
        result = subprocess.run(
            ["/usr/bin/xcrun", "swift", str(script), "--self-test-capture-contract"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("capture contract passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
