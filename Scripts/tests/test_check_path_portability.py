#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "ci" / "check-path-portability.py"
SPEC = importlib.util.spec_from_file_location("check_path_portability", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CHECK)


class PathPortabilityTests(unittest.TestCase):
    def test_colon_in_a_folder_name_is_rejected(self):
        self.assertEqual(
            CHECK.reasons("LokalBotTests/Fixtures/upgrade/0.9.6/library/meetings/2026/10/04-1:1-with-maya/meta.json"),
            ["illegal character"])

    def test_windows_separator_and_wildcards_are_rejected(self):
        for path in ("docs/a\\b.md", "notes/what?.md", "notes/star*.md", 'notes/"quoted".md', "a/b|c.txt"):
            with self.subTest(path=path):
                self.assertEqual(CHECK.reasons(path), ["illegal character"])

    def test_reserved_device_names_are_rejected_with_or_without_extension(self):
        for path in ("src/CON/readme.md", "src/nul.txt", "src/LPT1", "src/com3.log", "aux"):
            with self.subTest(path=path):
                self.assertEqual(CHECK.reasons(path), ["reserved device name"])

    def test_trailing_space_or_dot_is_rejected(self):
        self.assertEqual(CHECK.reasons("docs/notes. /a.md"), ["trailing space or dot"])
        self.assertEqual(CHECK.reasons("docs/trailing.dot./a.md"), ["trailing space or dot"])

    def test_ordinary_names_pass(self):
        for path in ("LokalBotTests/Fixtures/upgrade/0.13.2/library/meetings/2026/09/27-1-1-with-maya/meta.json",
                     "docs/v0.9.md", "a/b-c_d (1).txt", "Ünïcode/fichier.md", "src/console.rs", "src/auxiliary.rs"):
            with self.subTest(path=path):
                self.assertEqual(CHECK.reasons(path), [])

    def test_this_repository_has_no_path_a_windows_checkout_refuses(self):
        failures = [(path, reason) for path in CHECK.tracked_paths(ROOT) for reason in CHECK.reasons(path)]
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
