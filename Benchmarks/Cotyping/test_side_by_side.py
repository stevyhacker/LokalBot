"""Fail-closed completion checks for side-by-side cotyping evidence."""

import hashlib
from pathlib import Path
import tempfile
import unittest

import side_by_side


class SideBySideCompletionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cotyping-report-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = self.root / "prompts.tsv"
        self.manifest.write_text("one\tcontinuation\tA complete prompt\n", encoding="utf-8")
        self.rows = side_by_side.parse_manifest(self.manifest)

    def capture(self, target: str) -> Path:
        directory = self.root / target
        directory.mkdir()
        copied = directory / "prompts.tsv"
        copied.write_bytes(self.manifest.read_bytes())
        (directory / "one.png").write_bytes(b"png")
        (directory / "one.rect").write_text("1,2,300,200\n", encoding="utf-8")
        (directory / "one.txt").write_text("A complete prompt\n", encoding="utf-8")
        (directory / "one.document.txt").write_text("A complete prompt", encoding="utf-8")
        (directory / "one.accepted.txt").write_text("A complete prompt result", encoding="utf-8")
        digest = hashlib.sha256(copied.read_bytes()).hexdigest()
        (directory / "capture.complete").write_text(
            f"target={target}\nprompt_count=1\nmanifest_sha256={digest}\n"
            "input_mode=keys\naccept=1\n", encoding="utf-8")
        return directory

    def test_complete_leg_is_accepted(self):
        directory = self.capture("cotypist")
        side_by_side.validate_capture_directory(directory, "cotypist", self.rows, self.manifest)

    def test_missing_marker_artifact_or_usable_acceptance_is_rejected(self):
        directory = self.capture("lokalbot")
        marker = directory / "capture.complete"
        marker_text = marker.read_text(encoding="utf-8")
        marker.unlink()
        with self.assertRaisesRegex(ValueError, "marker"):
            side_by_side.validate_capture_directory(directory, "lokalbot", self.rows, self.manifest)

        marker.write_text(marker_text.replace("target=lokalbot", "target=other"), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "names"):
            side_by_side.validate_capture_directory(directory, "lokalbot", self.rows, self.manifest)

        marker.write_text(marker_text, encoding="utf-8")
        (directory / "one.png").unlink()
        with self.assertRaisesRegex(ValueError, "missing evidence"):
            side_by_side.validate_capture_directory(directory, "lokalbot", self.rows, self.manifest)

        (directory / "one.png").write_bytes(b"png")
        (directory / "one.accepted.txt").write_text("unrelated replacement", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "unusable"):
            side_by_side.validate_capture_directory(directory, "lokalbot", self.rows, self.manifest)


if __name__ == "__main__":
    unittest.main()
