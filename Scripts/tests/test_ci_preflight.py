"""Tests the CI control flow with a fake xcodebuild; never launches an app."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("preflight", SOURCE / "Scripts/release-preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "LokalBot").mkdir()
        (self.root / "Scripts/release-notes").mkdir(parents=True)
        (self.root / "LokalBot/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.8.1", "CFBundleVersion": "31"}))
        (self.root / "project.yml").write_text(
            '        CFBundleShortVersionString: "0.8.1"\n        CFBundleVersion: "31"\n')
        self.notes = self.root / "Scripts/release-notes/v0.8.1.md"
        self.notes.write_text('- Faster releases.\n\nhttps://github.com/stevyhacker/lokalbot/compare/v0.8.0...v0.8.1\n')

    def test_consistent_metadata(self):
        self.assertEqual(preflight.validate(self.root), ("0.8.1", "31", "v0.8.0"))

    def test_general_ci_accepts_prerelease_notes_or_generated_notes(self):
        shutil.copy2(SOURCE / "Scripts/release-preflight.py", self.root / "Scripts/release-preflight.py")
        workflow = (SOURCE / ".github/workflows/xcodegen.yml").read_text()
        command = next(line.strip() for line in workflow.splitlines()
                       if line.strip().startswith("python3 Scripts/release-preflight.py"))
        self.notes.unlink()
        beta_notes = self.notes.with_name("v0.8.1-beta.md")
        for has_notes in [True, False]:
            with self.subTest(prerelease_notes=has_notes):
                if has_notes:
                    beta_notes.write_text("- Beta release with tag-specific notes.\n")
                else:
                    beta_notes.unlink()
                result = subprocess.run(shlex.split(command), cwd=self.root, text=True,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode, 0, result.stdout)

    def test_stable_validation_still_requires_stable_notes(self):
        self.notes.rename(self.notes.with_name("v0.8.1-beta.md"))
        for mode in [{}, {"candidate": True}, {"staged": True}]:
            with self.subTest(mode=mode), self.assertRaises(FileNotFoundError):
                preflight.validate(self.root, **mode)

    def test_metadata_only_cannot_skip_candidate_or_staged_validation(self):
        for mode in [{"candidate": True}, {"staged": True}]:
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, "cannot be combined"):
                preflight.validate(self.root, metadata_only=True, **mode)

    def test_metadata_only_rejects_invalid_versions_and_builds(self):
        for version, build in [("0.8", "31"), ("0.8.1", "0"), ("0.8.1", "invalid")]:
            with self.subTest(version=version, build=build):
                (self.root / "LokalBot/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleShortVersionString": version, "CFBundleVersion": build}))
                with self.assertRaises(ValueError):
                    preflight.validate(self.root, metadata_only=True)

    def test_version_source_disagreement(self):
        (self.root / "project.yml").write_text('        CFBundleVersion: "30"\n')
        for metadata_only in [False, True]:
            with self.subTest(metadata_only=metadata_only), self.assertRaisesRegex(ValueError, "disagree"):
                preflight.validate(self.root, metadata_only=metadata_only)

    def test_wrong_requested_version(self):
        for metadata_only in [False, True]:
            with self.subTest(metadata_only=metadata_only), self.assertRaisesRegex(ValueError, "Requested"):
                preflight.validate(self.root, version="0.9.0", metadata_only=metadata_only)

    def test_missing_human_summary(self):
        self.notes.write_text('https://github.com/stevyhacker/lokalbot/compare/v0.8.0...v0.8.1\n')
        with self.assertRaisesRegex(ValueError, "human-readable"):
            preflight.validate(self.root)

    def test_changelog_points_to_wrong_release(self):
        self.notes.write_text(self.notes.read_text().replace('...v0.8.1', '...v0.9.0'))
        with self.assertRaisesRegex(ValueError, "compare"):
            preflight.validate(self.root)

    def test_published_tag_blocks_candidate(self):
        with patch.object(preflight, "git", side_effect=["", "existing remote tag"]):
            with self.assertRaisesRegex(ValueError, "already exists"):
                preflight.validate(self.root, candidate=True)

    def test_tag_lookup_failure_is_not_treated_as_absence(self):
        with patch.object(preflight, "git", side_effect=subprocess.CalledProcessError(128, "git")):
            with self.assertRaises(subprocess.CalledProcessError):
                preflight.validate(self.root, candidate=True)

    def test_unrelated_staged_files_are_rejected(self):
        with patch.object(preflight, "git", return_value="project.yml\nLokalBot/Info.plist\nScripts/release-notes/v0.8.1.md\nunrelated.txt"):
            with self.assertRaisesRegex(ValueError, "Stage only"):
                preflight.validate(self.root, staged=True)

    def test_candidate_requires_increasing_build_number(self):
        previous = plistlib.dumps({"CFBundleVersion": "31"})
        with patch.object(preflight, "git", side_effect=["", "", "v0.8.0", ""]):
            with patch.object(preflight.subprocess, "check_output", return_value=previous):
                with self.assertRaisesRegex(ValueError, "increase"):
                    preflight.validate(self.root, candidate=True)

    def test_staged_snapshot_must_match_validated_working_files(self):
        staged = "project.yml\nLokalBot/Info.plist\nScripts/release-notes/v0.8.1.md"
        with patch.object(preflight, "git", return_value=staged):
            with patch.object(preflight.subprocess, "check_output", return_value=b"outdated"):
                with self.assertRaisesRegex(ValueError, "Staged content differs"):
                    preflight.validate(self.root, staged=True)


class HostedRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ["Scripts/ui-tests.sh", "Scripts/ci/ui-build-stamp.py", "Scripts/ci/ui-shards.py",
                     "Scripts/ci/ui-durations.json", "Scripts/ci/prepare-display.swift", "Scripts/ci/compiler-cache.py"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / name, target)
        shutil.copytree(SOURCE / "LokalBotUITests", self.root / "LokalBotUITests")
        lock = self.root / "LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        lock.parent.mkdir(parents=True)
        lock.write_text('{}\n')
        (self.root / ".gitignore").write_text('.build/\n')
        self.git("init", "-q")
        # Short failure-path tests can finish while Git's background helpers
        # still touch .git, racing TemporaryDirectory cleanup on hosted Macs.
        self.git("config", "maintenance.auto", "false")
        self.git("config", "gc.auto", "0")
        self.git("config", "core.fsmonitor", "false")
        self.git("add", ".")
        self.git("-c", "user.name=CI Test", "-c", "user.email=ci@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        fake = self.root / ".build/bin/xcodebuild"
        fake.parent.mkdir(parents=True)
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
if args == ['-version']:
    print(os.environ.get('FAKE_XCODE', 'Xcode test\\nBuild version test'))
    sys.exit(0)
with open('.build/invocations.jsonl', 'a') as log:
    log.write(json.dumps(args) + '\\n')
if 'build-for-testing' in args:
    result = int(os.environ.get('FAKE_BUILD_EXIT', '0'))
    if 'COMPILATION_CACHE_ENABLE_CACHING=YES' in args:
        result = int(os.environ.get('FAKE_CACHE_EXIT', str(result)))
    if result == 0:
        p = pathlib.Path('.build/dd/Build/Products/Fixture.xctestrun')
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('fixture')
    sys.exit(result)
sys.exit(int(os.environ.get('FAKE_TEST_EXIT', '0')))
''')
        fake.chmod(0o755)
        sdk = fake.with_name('xcrun')
        sdk.write_text('#!/bin/sh\nprintf "%s\\n" "${FAKE_SDK:-test-sdk}"\n')
        sdk.chmod(0o755)
        display = fake.with_name('swift')
        display.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
assert sys.argv[1:] in (['Scripts/ci/prepare-display.swift'], ['Scripts/ci/prepare-display.swift', '--verify-only'])
assert pathlib.Path(sys.argv[1]).is_file()
with open('.build/invocations.jsonl', 'a') as log:
    log.write(json.dumps(['swift'] + sys.argv[1:]) + '\\n')
key = 'FAKE_DISPLAY_VERIFY_EXIT' if '--verify-only' in sys.argv else 'FAKE_DISPLAY_EXIT'
sys.exit(int(os.environ.get(key, '0')))
''')
        display.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{fake.parent}:{os.environ['PATH']}", CI="true",
                        GITHUB_ACTIONS="true", GITHUB_RUN_ID="fixture", GITHUB_RUN_ATTEMPT="1", GITHUB_JOB="ui",
                        CODE_SIGNING_ALLOWED="NO", GITHUB_STEP_SUMMARY=str(self.root / '.build/summary'))

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True)

    def run_script(self, *args, script="Scripts/ui-tests.sh", **environment):
        interpreter = 'python3' if script.endswith('.py') else 'bash'
        return subprocess.run([interpreter, script, *args], cwd=self.root,
                              env=dict(self.env, **environment), text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def calls(self):
        path = self.root / '.build/invocations.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def build(self):
        result = self.run_script('--build-only')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_one_build_for_multiple_test_runs(self):
        self.build()
        for name in ['First/testA', 'Second/testB']:
            result = self.run_script('--test-only', '--only', name)
            self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(sum('build-for-testing' in call for call in self.calls()), 1)
        self.assertEqual(sum('test-without-building' in call for call in self.calls()), 2)

    def test_failure_invalidates_old_build_and_propagates_exit(self):
        self.build()
        self.assertEqual(self.run_script('--build-only', FAKE_BUILD_EXIT='71').returncode, 71)
        self.assertNotEqual(self.run_script('--test-only').returncode, 0)
        self.assertFalse(any('test-without-building' in call for call in self.calls()))

    def test_display_failure_stops_before_test_launch(self):
        self.build()
        result = self.run_script('--test-only', FAKE_DISPLAY_EXIT='63')
        self.assertEqual(result.returncode, 63, result.stdout)
        self.assertEqual(self.calls()[-1], ['swift', 'Scripts/ci/prepare-display.swift'])
        self.assertFalse(any('test-without-building' in call for call in self.calls()))

    def test_reverted_display_stops_before_test_launch(self):
        self.build()
        result = self.run_script('--test-only', FAKE_DISPLAY_VERIFY_EXIT='64')
        self.assertEqual(result.returncode, 64, result.stdout)
        self.assertEqual(self.calls()[-2:], [['swift', 'Scripts/ci/prepare-display.swift'],
                                        ['swift', 'Scripts/ci/prepare-display.swift', '--verify-only']])

    def test_build_producer_never_prepares_or_launches_display(self):
        self.build()
        self.assertFalse(any('swift' in call or 'test-without-building' in call for call in self.calls()))

    def test_cached_build_still_compiles_and_writes_fresh_stamp(self):
        self.build()
        for mode in ['warm', 'cold', 'off']:
            result = self.run_script('--build-only', COMPILER_CACHE_MODE=mode)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertTrue((self.root / '.build/dd/ui-build.json').is_file())
        self.assertEqual(sum('build-for-testing' in call for call in self.calls()), 4)

    def test_failed_cached_build_falls_back_once_and_never_reuses_stamp(self):
        self.build()
        result = self.run_script('--build-only', COMPILER_CACHE_MODE='warm', FAKE_BUILD_EXIT='71')
        self.assertEqual(result.returncode, 71, result.stdout)
        builds = [c for c in self.calls() if 'build-for-testing' in c]
        self.assertEqual(len(builds), 3)
        self.assertIn('COMPILATION_CACHE_ENABLE_CACHING=NO', builds[-1])
        self.assertFalse((self.root / '.build/dd/ui-build.json').exists())
        self.assertNotEqual(self.run_script('--test-only').returncode, 0)

    def test_successful_clean_fallback_builds_fresh_products_without_saving_bad_cache(self):
        result = self.run_script('--build-only', COMPILER_CACHE_MODE='warm', FAKE_CACHE_EXIT='71')
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads((self.root / '.build/ci/compile.json').read_text())
        self.assertEqual([a['exit'] for a in report['attempts']], [71, 0])
        self.assertFalse(report['attempts'][-1]['caching'])
        self.assertTrue((self.root / '.build/dd/ui-build.json').is_file())
        self.assertEqual(self.run_script('--test-only').returncode, 0)

    def test_changed_app_or_test_inputs_cannot_use_existing_build(self):
        self.build()
        for name in ['LokalBot/New.swift', 'LokalBotUITests/New.swift']:
            target = self.root / name
            target.parent.mkdir(exist_ok=True)
            target.write_text('// new input\n')
            self.assertNotEqual(self.run_script('--test-only').returncode, 0)
            target.unlink()
        self.assertFalse(any('test-without-building' in call for call in self.calls()))

    def test_stale_job_toolchain_and_dirty_inputs_are_rejected(self):
        self.build()
        for env in [dict(GITHUB_RUN_ATTEMPT='2'), dict(FAKE_XCODE='different compiler'), dict(FAKE_SDK='different SDK')]:
            self.assertNotEqual(self.run_script('--test-only', **env).returncode, 0)
        (self.root / 'Scripts/ui-tests.sh').write_text((self.root / 'Scripts/ui-tests.sh').read_text() + '\n# changed\n')
        self.assertNotEqual(self.run_script('--test-only').returncode, 0)
        self.assertFalse(any('test-without-building' in call for call in self.calls()))

    def test_reuse_never_starts_local_ui_implicitly(self):
        self.assertNotEqual(self.run_script('--test-only', CI='').returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_new_commit_and_missing_products_require_rebuild(self):
        self.build()
        products = self.root / '.build/dd/Build/Products/Fixture.xctestrun'
        products.unlink()
        self.assertNotEqual(self.run_script('--test-only').returncode, 0)
        products.write_text('fixture')
        self.git('-c', 'user.name=CI Test', '-c', 'user.email=ci@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'new candidate')
        self.assertNotEqual(self.run_script('--test-only').returncode, 0)
        self.assertFalse(any('test-without-building' in call for call in self.calls()))

    def test_ci_logging_pipeline_stops_before_smoke_when_compilation_fails(self):
        workflow = (SOURCE / '.github/workflows/ui-tests.yml').read_text()
        self.assertIn('shell: bash', workflow)  # GHA enables -e -o pipefail for an explicit Bash shell.
        step = workflow.split('      - name: Build UI test targets\n', 1)[1].split('      - name:', 1)[0]
        run = step.split('        run: |\n', 1)[1]
        run = '\n'.join(line[10:] for line in run.splitlines() if line.startswith('          '))
        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c',
                                 run + '\npython3 Scripts/ci/ui-shards.py run smoke'],
                                cwd=self.root, env=dict(self.env, FAKE_BUILD_EXIT='71'),
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 71, result.stdout)
        self.assertFalse(any('test-without-building' in call for call in self.calls()))

    def test_test_failure_survives_log_pipe_and_summary(self):
        self.build()
        result = self.run_script('run', 'smoke', script='Scripts/ci/ui-shards.py', FAKE_TEST_EXIT='42')
        self.assertEqual(result.returncode, 42, result.stdout)
        self.assertIn('exit 42', (self.root / '.build/summary').read_text())


if __name__ == '__main__':
    unittest.main()
