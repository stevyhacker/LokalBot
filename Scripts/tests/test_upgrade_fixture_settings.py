import importlib.util
import json
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("settings", SOURCE / "Scripts/upgrade-fixtures/settings.py")
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)


class UpgradeSettingsTests(unittest.TestCase):
    def test_every_profile_approves_the_remote_server_and_schedules_work(self):
        for version in settings.committed_versions():
            with self.subTest(version=version):
                value = json.loads(settings.profile(version))
                self.assertEqual(value["summarizerBackend"], "OpenAI-compatible server")
                self.assertIn("https://openrouter.ai", value["approvedRemoteInferenceOrigins"])
                self.assertTrue(value["dayDigestAutoEnabled"])
                self.assertTrue(value["dreamingEnabled"])

    def test_only_0_9_0_and_0_9_1_carry_the_old_automation_approval(self):
        # The separate approval for scheduled remote runs existed only in
        # 0.9.0 and 0.9.1; 0.9.2 removed it (#113).
        for version in settings.committed_versions():
            with self.subTest(version=version):
                carried = "approvedRemoteAutomationOrigins" in json.loads(settings.profile(version))
                self.assertEqual(carried, version in {"0.9.0", "0.9.1"})

    def test_fixture_keys_are_deterministic_and_32_bytes(self):
        self.assertEqual(len(bytes.fromhex(settings.fixture_key_hex("screenshot-key"))), 32)
        self.assertEqual(settings.fixture_key_hex("chat-key"), settings.fixture_key_hex("chat-key"))

    def test_committed_versions_are_the_fixture_folders_in_release_order(self):
        versions = settings.committed_versions()
        folders = {path.name for path in (SOURCE / "LokalBotTests/Fixtures/upgrade").iterdir() if path.is_dir()}
        self.assertEqual(set(versions), folders)
        self.assertEqual(versions, sorted(versions, key=settings._tuple))
        self.assertEqual(versions[0], "0.6.2")
        # 0.10.10 sorts after 0.10.9, not after 0.10.1.
        self.assertLess(versions.index("0.10.9"), versions.index("0.10.10"))

    def test_plan_builds_the_requested_release_or_the_committed_fixtures(self):
        newest = settings.committed_versions()[-1]
        self.assertEqual(settings.plan("push", ["v0.11.2"]), ["0.11.2"])
        self.assertEqual(settings.plan("workflow_dispatch", ["0.10.9", "0.11.1"]), ["0.10.9", "0.11.1"])
        self.assertEqual(settings.plan("workflow_dispatch", []), settings.committed_versions())
        self.assertEqual(settings.plan("pull_request", []), [newest])

    def test_plan_refuses_anything_but_a_stable_version(self):
        for value in ["v1.0.0-beta", "0.11", "0.11.2; rm -rf /", ""]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    settings.plan("workflow_dispatch", [value])

    def test_workflow_takes_its_matrix_from_the_plan(self):
        workflow = (SOURCE / ".github/workflows/upgrade-fixtures.yml").read_text()
        self.assertIn("version: ${{ fromJSON(needs.plan.outputs.versions) }}", workflow)
        self.assertNotIn('version: ["', workflow)

    def test_release_builds_its_own_fixture_after_publishing(self):
        release = (SOURCE / ".github/workflows/release.yml").read_text()
        job = release.split("\n  upgrade-fixture:\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn("needs: release", job)
        self.assertIn("uses: ./.github/workflows/upgrade-fixtures.yml", job)
        self.assertIn("tag: ${{ github.ref_name }}", job)


if __name__ == "__main__":
    unittest.main()
