"""A crate compiled into the sync library only on Apple or Android needs a notice somewhere."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("notices", ROOT / "Scripts/ci/check-sync-crate-notices.py")
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)

GENERATED = """## License texts

### MIT License

Used by:

- chrono 0.4.45 (https://github.com/chronotope/chrono)
- iana-time-zone 0.1.65 (https://github.com/strawlab/iana-time-zone)
"""
TREE = """lokalbot-sync v0.12.2 (/work/LinuxWindows/crates/lokalbot-sync)
chrono v0.4.45
iana-time-zone v0.1.65
core-foundation-sys v0.8.7
serde_derive v1.0.228 (proc-macro)
"""


class SyncCrateNoticeTests(unittest.TestCase):
    def test_the_tree_is_read_without_our_own_crates(self):
        self.assertEqual(notices.tree_crates(TREE), {
            ("chrono", "0.4.45"), ("iana-time-zone", "0.1.65"), ("core-foundation-sys", "0.8.7"),
            ("serde_derive", "1.0.228")})

    def test_a_crate_neither_file_names_is_reported_with_its_version(self):
        crates = notices.tree_crates(TREE)
        self.assertEqual(notices.unnamed(crates, GENERATED, ""),
                         [("core-foundation-sys", "0.8.7"), ("serde_derive", "1.0.228")])
        hand_written = "| core-foundation-sys 0.8.7 | macOS | MIT |\n| serde_derive 1.0.228 | all | MIT |"
        self.assertEqual(notices.unnamed(crates, GENERATED, hand_written), [])
        # A notice for another version of the crate does not cover this one.
        self.assertEqual(notices.unnamed(crates, GENERATED, hand_written.replace("0.8.7", "0.8.6")),
                         [("core-foundation-sys", "0.8.7")])

    def test_the_targets_are_the_ones_the_build_scripts_use(self):
        apple = (ROOT / "Scripts/build-sync-xcframework.sh").read_text(encoding="utf-8")
        android = (ROOT / "Scripts/build-sync-android.sh").read_text(encoding="utf-8")
        built = set(apple.split("TARGETS=(", 1)[1].split(")", 1)[0].split())
        built |= set(android.split("RUST_TARGETS=(", 1)[1].split(")", 1)[0].split())
        self.assertEqual(set(notices.TARGETS), built)

    def test_the_license_workflow_runs_the_check(self):
        workflow = (ROOT / ".github/workflows/third-party-licenses.yml").read_text(encoding="utf-8")
        self.assertIn("python3 ../Scripts/ci/check-sync-crate-notices.py", workflow)
        self.assertEqual(workflow.count('- "THIRD_PARTY_NOTICES.md"'), 2)


if __name__ == "__main__":
    unittest.main()
