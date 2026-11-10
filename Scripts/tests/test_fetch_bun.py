"""fetch-bun.sh must keep finding the pins AgentRuntimeManifest trusts."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class FetchBunPinTests(unittest.TestCase):
    def test_pins_are_parsed_from_the_runtime_manifest(self):
        output = subprocess.check_output(["bash", str(ROOT / "Scripts/ci/fetch-bun.sh"), "--print-pins"], text=True)
        version, zip_sha, bin_sha = output.split()
        source = (ROOT / "LokalBot/Agent/AgentRuntime.swift").read_text()
        self.assertIn(f'static let bunVersion = "{version}"', source)
        self.assertRegex(zip_sha, r"^[0-9a-f]{64}$")
        self.assertRegex(bin_sha, r"^[0-9a-f]{64}$")
        self.assertIn(zip_sha, source)
        self.assertIn(bin_sha, source)


if __name__ == "__main__":
    unittest.main()
