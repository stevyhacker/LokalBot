#!/usr/bin/env python3
"""Regression tests for the demo library destination ownership boundary."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "seed_demo_library.py"
SPEC = importlib.util.spec_from_file_location("seed_demo_library", SCRIPT)
SEEDER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SEEDER)


class DemoLibraryDestinationTests(unittest.TestCase):
    def run_main(self, *arguments):
        # The ownership decision happens before fixture generation. Stub the
        # expensive audio/data writers so these tests exercise that real CLI
        # boundary without depending on codecs or creating benchmark data.
        with mock.patch.object(sys, "argv", [str(SCRIPT), *map(str, arguments)]), \
             mock.patch.object(SEEDER, "build", return_value=[]), \
             mock.patch.object(SEEDER, "seed_chats"), \
             mock.patch.object(SEEDER, "seed_journal"), \
             mock.patch.object(SEEDER, "seed_activity"):
            SEEDER.main()

    def test_populated_unowned_directory_is_never_removed(self):
        with tempfile.TemporaryDirectory(prefix="lokalbot-demo-destination-") as temporary:
            root = Path(temporary) / "existing-library"
            root.mkdir()
            sentinel = root / "keep-me.txt"
            sentinel.write_text("user data\n", encoding="utf-8")

            for arguments in ((root,), ("--reset", root)):
                with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                    self.run_main(*arguments)
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "user data\n")
                self.assertFalse((root / SEEDER.OWNERSHIP_MARKER).exists())

    def test_marked_directory_requires_reset_and_then_only_its_contents_are_replaced(self):
        with tempfile.TemporaryDirectory(prefix="lokalbot-demo-destination-") as temporary:
            root = Path(temporary) / "owned-library"
            root.mkdir()
            marker = root / SEEDER.OWNERSHIP_MARKER
            marker.write_text("LokalBot synthetic demo library\n", encoding="utf-8")
            stale = root / "stale-fixture.txt"
            stale.write_text("old fixture\n", encoding="utf-8")

            with self.assertRaises(SystemExit):
                self.run_main(root)
            self.assertTrue(stale.exists())

            self.run_main("--reset", root)
            self.assertFalse(stale.exists())
            self.assertEqual(marker.read_text(encoding="utf-8"),
                             "LokalBot synthetic demo library\n")
            self.assertTrue((root / "meetings").is_dir())


if __name__ == "__main__":
    unittest.main()
