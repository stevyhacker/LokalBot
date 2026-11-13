"""Pull requests that cannot affect the UI still report a passing UI gate."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("relevance", SOURCE / "Scripts/ci/ui-relevance.py")
relevance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relevance)


class UIRelevanceTests(unittest.TestCase):
    def test_docs_and_web_changes_do_not_need_the_ui_suite(self):
        self.assertFalse(relevance.relevant(["README.md", "Docs/plan.md", "Website/public/index.html"]))

    def test_app_ui_test_and_ci_changes_need_the_ui_suite(self):
        for path in ["LokalBot/AppState.swift", "LokalBotUITests/MainWindowUITests.swift",
                     "project.yml", "Scripts/ci/ui-shards.py", "Scripts/test/ui-tests.sh",
                     ".github/workflows/ui-tests.yml", "Scripts/build/fetch-llama.sh",
                     "LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]:
            with self.subTest(path=path):
                self.assertTrue(relevance.relevant([path]))

    def test_prefix_patterns_do_not_match_sibling_names(self):
        self.assertFalse(relevance.relevant(["LokalBotTests/Foo.swift"]))
        self.assertFalse(relevance.relevant(["LokalBot-notes.md"]))

    def test_draft_pull_requests_wait_for_ready_for_review(self):
        with tempfile.NamedTemporaryFile("r") as output, patch.dict(os.environ, {
                "GITHUB_EVENT_NAME": "pull_request", "PULL_REQUEST_DRAFT": "true", "GITHUB_OUTPUT": output.name}), \
                patch.object(relevance, "changed_paths", return_value=["LokalBot/AppState.swift"]):
            self.assertEqual(relevance.main(["ui-relevance.py", "base", "head"]), 0)
            self.assertEqual(Path(output.name).read_text(), "relevant=false\n")
        workflow = (SOURCE / ".github/workflows/ui-tests.yml").read_text()
        trigger = workflow.split("\n  pull_request:\n", 1)[1].split("\n  schedule:", 1)[0]
        self.assertIn("ready_for_review", trigger)
        self.assertIn("PULL_REQUEST_DRAFT: ${{ github.event.pull_request.draft }}", workflow)

    def test_size_warning_only_above_sixty_files(self):
        self.assertIsNone(relevance.size_warning([f"f{i}" for i in range(60)]))
        warning = relevance.size_warning([f"f{i}" for i in range(61)])
        self.assertTrue(warning.startswith("::warning::"))
        self.assertIn("61 files", warning)


if __name__ == "__main__":
    unittest.main()
