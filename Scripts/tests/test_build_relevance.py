"""Pull requests that cannot change the build still report Build's checks."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("build_relevance", SOURCE / "Scripts/ci/build-relevance.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class BuildRelevanceTests(unittest.TestCase):
    def test_docs_website_assets_and_video_skip_the_build(self):
        self.assertFalse(build.relevant([
            "README.md", "AGENTS.md", "DEVELOPMENT.md", "RELEASING.md", "Docs/plan.md", "web/index.html",
            "Assets/lokalbot-icon.svg", "Video/demo/index.html", "Distribution/homebrew/README.md",
            ".github/PULL_REQUEST_TEMPLATE.md", "cloudflare/worker.ts", "wrangler.jsonc",
        ]))

    def test_bundled_files_benchmarks_code_and_ci_build(self):
        for path in ["PRIVACY.md", "LICENSE", "LICENSES/AGPL-3.0.txt", "THIRD_PARTY_NOTICES.md",
                     ".agents/skills/lokalbot-cli/SKILL.md",
                     "Benchmarks/Cotyping/heldout.jsonl", "LokalBot/AppState.swift", "LokalBotTests/X.swift",
                     "CLI/main.swift", "project.yml", "Scripts/unit-tests.sh", ".github/workflows/build.yml",
                     "LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]:
            with self.subTest(path=path):
                self.assertTrue(build.relevant([path]))
                self.assertTrue(build.relevant(["Docs/plan.md", path]), "one buildable path builds")

    def test_empty_diff_builds(self):
        self.assertTrue(build.relevant([]))

    def test_non_pull_request_events_always_build(self):
        with tempfile.NamedTemporaryFile("r") as output:
            for event in ["push", "schedule", "workflow_dispatch"]:
                with self.subTest(event=event), patch.dict(os.environ, {"GITHUB_EVENT_NAME": event,
                                                                         "GITHUB_OUTPUT": output.name}):
                    self.assertEqual(build.main(["build-relevance.py", "", ""]), 0)
            self.assertEqual(Path(output.name).read_text().splitlines(), ["relevant=true"] * 3)


if __name__ == "__main__":
    unittest.main()
