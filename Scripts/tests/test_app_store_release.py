"""Tests for the App Store upload script, its workflow and how Release calls it."""

from __future__ import annotations

import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("publish_app_store", ROOT / "Scripts/release/publish_app_store.py")
store = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(store)

BUNDLE_ID = "me.dotenv.LokalBot.companion"


def make_ipa(path: Path, *, version: str = "0.13.4", build: str = "70", signed: bool = True) -> None:
    info = {"CFBundleIdentifier": BUNDLE_ID, "CFBundleShortVersionString": version, "CFBundleVersion": build}
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("Payload/LokalBot.app/Info.plist", plistlib.dumps(info))
        archive.writestr("Payload/LokalBot.app/LokalBot", b"binary")
        if signed:
            archive.writestr("Payload/LokalBot.app/_CodeSignature/CodeResources", b"<plist/>")


def run_step(job: str, name: str, **variables: str) -> tuple[int, str, str]:
    step = job.split(f"      - name: {name}\n", 1)[1]
    body = []
    for line in step.split("        run: |\n", 1)[1].splitlines():
        if line.strip() and not line.startswith(" " * 10):
            break
        body.append(line[10:])
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder) / "output"
        output.touch()
        done = subprocess.run(
            ["bash", "-e", "-c", "\n".join(body)],
            capture_output=True,
            text=True,
            env=dict(os.environ, GITHUB_OUTPUT=str(output), **variables),
        )
        return done.returncode, output.read_text().strip(), done.stdout + done.stderr


class FakeConnect:
    """Stands in for App Store Connect: answers from a small in-memory account."""

    key_id = "KEY123"
    issuer_id = "issuer-1"
    key_file = Path("AuthKey_KEY123.p8")

    def __init__(self, *, builds=None, versions=None, drafts=None, compliance=False, localizations=("en-US", "sr")):
        self.builds = list(builds or [])
        self.versions = list(versions or [])
        self.drafts = list(drafts or [])
        self.compliance = compliance
        self.localizations = localizations
        self.calls: list[tuple[str, str, dict | None]] = []

    def upload(self, version: str, build: str) -> None:
        self.builds.append({
            "id": "build-new",
            "attributes": {"version": build, "processingState": "VALID", "usesNonExemptEncryption": self.compliance},
            "marketing": version,
        })

    def call(self, method, path, *, query=None, body=None):
        self.calls.append((method, path, body))
        query = query or {}
        if (method, path) == ("GET", "/apps"):
            return {"data": [{"id": "app-1", "attributes": {"bundleId": query["filter[bundleId]"]}}]}
        if (method, path) == ("GET", "/builds"):
            found = [b for b in self.builds if b["attributes"]["version"] == query["filter[version]"]
                     and b["marketing"] == query["filter[preReleaseVersion.version]"]]
            return {"data": found}
        if (method, path) == ("GET", "/apps/app-1/appStoreVersions"):
            if "filter[versionString]" in query:
                return {"data": [v for v in self.versions
                                 if v["attributes"]["versionString"] == query["filter[versionString]"]]}
            states = query["filter[appVersionState]"].split(",")
            return {"data": [v for v in self.versions if v["attributes"]["appVersionState"] in states]}
        if (method, path) == ("POST", "/appStoreVersions"):
            created = {"id": "version-new", "attributes": dict(body["data"]["attributes"],
                                                               appVersionState="PREPARE_FOR_SUBMISSION")}
            self.versions.append(created)
            return {"data": created}
        if method == "PATCH" and re.fullmatch(r"/appStoreVersions/[^/]+", path):
            target = next(v for v in self.versions if v["id"] == path.rsplit("/", 1)[1])
            target["attributes"].update(body["data"]["attributes"])
            return {"data": target}
        if method == "PATCH" and path.endswith("/relationships/build"):
            return {}
        if method == "GET" and path.endswith("/appStoreVersionLocalizations"):
            return {"data": [{"id": f"loc-{locale}", "attributes": {"locale": locale}} for locale in self.localizations]}
        if method == "PATCH" and path.startswith("/appStoreVersionLocalizations/"):
            return {}
        if (method, path) == ("GET", "/reviewSubmissions"):
            return {"data": self.drafts}
        if (method, path) == ("POST", "/reviewSubmissions"):
            return {"data": {"id": "submission-new"}}
        if (method, path) == ("POST", "/reviewSubmissionItems"):
            return {"data": {"id": "item-1"}}
        if method == "PATCH" and path.startswith("/reviewSubmissions/"):
            return {"data": {"id": path.rsplit("/", 1)[1]}}
        raise AssertionError((method, path))

    def made(self, method: str, prefix: str) -> list[dict | None]:
        return [body for verb, path, body in self.calls if verb == method and path.startswith(prefix)]


class WhatsNewTests(unittest.TestCase):
    def test_keeps_only_bullets_tagged_for_iphone_or_ipad(self):
        notes = (
            "## What’s new\n\n"
            "- **Apple Speech transcription (Mac, macOS 26+).** Choose **Apple Speech** in Settings.\n"
            "- **Record from the lock screen (iPhone and iPad).** Start a recording from a "
            "[Control Center](https://example.com) button with `Record`.\n"
            "- **Faster meeting search (all platforms).** A prefilter skips transcripts.\n"
            "<!-- no explainer: small -->\n\n"
            "## Improvements\n\n"
            "- **Fixed:** the meeting list keeps its place after a sync (iPad).\n"
            "- **Pairing code is easier to scan (iPhone, iPad and Android).** Matches the Android app.\n\n"
            "The Android app is on Google Play. The iPhone and iPad app isn't in the App Store yet.\n\n"
            "**Full changelog:** https://github.com/stevyhacker/lokalbot/compare/v0.13.3...v0.13.4\n"
        )
        self.assertEqual(
            store.format_whats_new(notes),
            "• Record from the lock screen. Start a recording from a Control Center button with Record.\n"
            "• Fixed: the meeting list keeps its place after a sync.",
        )

    def test_notes_without_phone_bullets_fall_back_to_a_plain_line(self):
        notes = "- **Windows installer (Windows).** Adds the CLI to PATH.\n"
        self.assertEqual(store.format_whats_new(notes), store.WHATS_NEW_FALLBACK)
        self.assertEqual(store.format_whats_new(""), store.WHATS_NEW_FALLBACK)

    def test_long_notes_are_cut_at_a_bullet(self):
        notes = "\n".join(f"- **Change {index} (iPhone).** {'Detail. ' * 40}" for index in range(30))
        formatted = store.format_whats_new(notes)
        self.assertLessEqual(len(formatted), store.WHATS_NEW_LIMIT)
        self.assertTrue(formatted.endswith("…"))
        self.assertNotIn("(iPhone)", formatted)


class IpaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_reads_identifier_version_and_build(self):
        ipa = self.root / "LokalBot.ipa"
        make_ipa(ipa)
        self.assertEqual(store.read_ipa_version(ipa), (BUNDLE_ID, "0.13.4", "70"))

    def test_refuses_an_unsigned_app_and_other_archives(self):
        unsigned = self.root / "unsigned.ipa"
        make_ipa(unsigned, signed=False)
        with self.assertRaisesRegex(ValueError, "not signed"):
            store.read_ipa_version(unsigned)
        other = self.root / "other.ipa"
        with zipfile.ZipFile(other, "w") as archive:
            archive.writestr("BundleConfig.pb", b"android")
        with self.assertRaisesRegex(ValueError, "not an iOS app archive"):
            store.read_ipa_version(other)
        with self.assertRaisesRegex(ValueError, "not found"):
            store.read_ipa_version(self.root / "missing.ipa")


class TokenTests(unittest.TestCase):
    def test_der_signature_becomes_fixed_width(self):
        r = (1).to_bytes(1, "big")
        s = b"\x00" + b"\xff" * 32
        der = b"\x30" + bytes([2 + len(r) + 2 + len(s)]) + b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
        raw = store.der_to_raw_signature(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], b"\x00" * 31 + b"\x01")
        self.assertEqual(raw[32:], b"\xff" * 32)
        with self.assertRaises(ValueError):
            store.der_to_raw_signature(b"\x31\x00")
        with self.assertRaises(ValueError):
            store.der_to_raw_signature(b"\x30\x06\x02\x01")

    @unittest.skipUnless(shutil.which("openssl"), "openssl required")
    def test_token_verifies_with_the_public_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sec1 = root / "sec1.pem"
            key = root / "AuthKey_KEY123.p8"
            public = root / "public.pem"
            quiet = dict(check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(sec1)], **quiet)
            subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(sec1), "-out", str(key)], **quiet)
            subprocess.run(["openssl", "ec", "-in", str(sec1), "-pubout", "-out", str(public)], **quiet)

            token = store.make_token("KEY123", "issuer-1", key, now=1700000000)
            header_b64, claims_b64, signature_b64 = token.split(".")
            header = json.loads(base64.urlsafe_b64decode(header_b64 + "=="))
            claims = json.loads(base64.urlsafe_b64decode(claims_b64 + "=="))
            self.assertEqual(header, {"alg": "ES256", "kid": "KEY123", "typ": "JWT"})
            self.assertEqual(claims, {"iss": "issuer-1", "iat": 1700000000, "exp": 1700000900,
                                      "aud": "appstoreconnect-v1"})
            self.assertLessEqual(claims["exp"] - claims["iat"], 1200)

            raw = base64.urlsafe_b64decode(signature_b64 + "==")
            self.assertEqual(len(raw), 64)

            def integer(value: bytes) -> bytes:
                value = value.lstrip(b"\x00") or b"\x00"
                if value[0] & 0x80:
                    value = b"\x00" + value
                return b"\x02" + bytes([len(value)]) + value

            body = integer(raw[:32]) + integer(raw[32:])
            signature = root / "signature.der"
            signature.write_bytes(b"\x30" + bytes([len(body)]) + body)
            verify = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(signature)],
                input=f"{header_b64}.{claims_b64}".encode("ascii"),
                capture_output=True,
            )
            self.assertEqual(verify.returncode, 0, verify.stderr.decode("utf-8", errors="replace"))

    def test_client_renews_its_token_while_a_release_waits(self):
        api = store.Connect("KEY123", "issuer-1", Path("AuthKey_KEY123.p8"))
        clock = [1000.0]
        tokens = iter(["first", "second"])
        seen = []

        def fake_http(method, url, *, token, body=None, timeout=120):
            seen.append((url, token))
            return {}

        with patch.object(store, "make_token", side_effect=lambda *args, **kwargs: next(tokens)), \
                patch.object(store, "http_json", side_effect=fake_http), \
                patch.object(store.time, "time", side_effect=lambda: clock[0]):
            api.call("GET", "/apps", query={"filter[bundleId]": BUNDLE_ID})
            clock[0] += 300
            api.call("GET", "/builds")
            clock[0] += 400
            api.call("GET", "/builds")
        self.assertEqual([token for _, token in seen], ["first", "first", "second"])
        self.assertEqual(seen[0][0], f"{store.API_BASE}/apps?filter%5BbundleId%5D={BUNDLE_ID}")


class PublishFlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ipa = Path(self.temp.name) / "LokalBot.ipa"
        make_ipa(self.ipa)
        self.altool_calls: list[str] = []
        sleeper = patch.object(store.time, "sleep")
        sleeper.start()
        self.addCleanup(sleeper.stop)

    def altool(self, api: FakeConnect):
        def run(action, ipa_path, key_id, issuer_id, key_file):
            self.altool_calls.append(action)
            self.assertEqual((key_id, issuer_id, key_file), (api.key_id, api.issuer_id, api.key_file))
            if action == "--upload-app":
                api.upload("0.13.4", "70")
        return run

    def publish(self, api: FakeConnect, **options):
        options.setdefault("release", "review")
        options.setdefault("whats_new", "• Record from the lock screen.")
        return store.publish(api=api, ipa_path=self.ipa, altool=self.altool(api), **options)

    def test_review_uploads_creates_the_version_and_submits_it(self):
        api = FakeConnect()
        result = self.publish(api, expected_version="0.13.4")
        self.assertEqual(result, {"result": "submitted", "appStoreVersion": "created", "bundleId": BUNDLE_ID,
                                  "version": "0.13.4", "build": "70", "release": "review", "uploaded": True})
        self.assertEqual(self.altool_calls, ["--upload-app"])
        created = api.made("POST", "/appStoreVersions")[0]["data"]
        self.assertEqual(created["attributes"],
                         {"platform": "IOS", "versionString": "0.13.4", "releaseType": "AFTER_APPROVAL"})
        self.assertEqual(created["relationships"]["app"]["data"], {"type": "apps", "id": "app-1"})
        self.assertEqual(api.made("PATCH", "/appStoreVersions/version-new/relationships/build"),
                         [{"data": {"type": "builds", "id": "build-new"}}])
        notes = api.made("PATCH", "/appStoreVersionLocalizations/")
        self.assertEqual(len(notes), 2)
        self.assertEqual({body["data"]["attributes"]["whatsNew"] for body in notes}, {"• Record from the lock screen."})
        item = api.made("POST", "/reviewSubmissionItems")[0]["data"]["relationships"]
        self.assertEqual(item["reviewSubmission"]["data"]["id"], "submission-new")
        self.assertEqual(item["appStoreVersion"]["data"]["id"], "version-new")
        self.assertEqual(api.made("PATCH", "/reviewSubmissions/submission-new"),
                         [{"data": {"type": "reviewSubmissions", "id": "submission-new",
                                    "attributes": {"submitted": True}}}])
        order = [path for _, path, _ in api.calls]
        self.assertLess(order.index("/appStoreVersions/version-new/relationships/build"),
                        order.index("/reviewSubmissions/submission-new"))

    def test_manual_mode_holds_the_approved_version(self):
        api = FakeConnect()
        self.assertEqual(self.publish(api, release="manual")["result"], "submitted")
        self.assertEqual(api.made("POST", "/appStoreVersions")[0]["data"]["attributes"]["releaseType"], "MANUAL")

    def test_testflight_mode_stops_after_processing(self):
        api = FakeConnect(compliance=None)
        result = self.publish(api, release="testflight")
        self.assertEqual((result["result"], result["uploaded"]), ("uploaded", True))
        self.assertEqual(api.made("POST", "/appStoreVersions"), [])
        self.assertEqual(api.made("POST", "/reviewSubmissions"), [])

    def test_a_rerun_does_not_upload_the_same_build_twice(self):
        api = FakeConnect()
        api.upload("0.13.4", "70")
        result = self.publish(api)
        self.assertEqual((result["result"], result["uploaded"]), ("submitted", False))
        self.assertEqual(self.altool_calls, [])

    def test_a_version_already_in_review_is_left_alone(self):
        for state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "READY_FOR_DISTRIBUTION"):
            with self.subTest(state=state):
                api = FakeConnect(versions=[{"id": "version-1", "attributes": {
                    "versionString": "0.13.4", "appVersionState": state}}])
                api.upload("0.13.4", "70")
                result = self.publish(api)
                self.assertEqual((result["result"], result["state"]), ("already_submitted", state))
                self.assertEqual([call for call in api.calls if call[0] != "GET"], [])

    def test_a_leftover_editable_version_is_renamed_instead_of_creating_a_second(self):
        api = FakeConnect(versions=[{"id": "version-old", "attributes": {
            "versionString": "0.13.3", "appVersionState": "PREPARE_FOR_SUBMISSION"}}])
        result = self.publish(api)
        self.assertEqual(result["appStoreVersion"], "renamed")
        self.assertEqual(api.made("POST", "/appStoreVersions"), [])
        self.assertEqual(api.versions[0]["attributes"]["versionString"], "0.13.4")
        self.assertEqual(api.versions[0]["attributes"]["releaseType"], "AFTER_APPROVAL")

    def test_a_version_already_in_an_unsent_submission_is_not_added_twice(self):
        api = FakeConnect(
            versions=[{"id": "version-1", "attributes": {"versionString": "0.13.4",
                                                         "appVersionState": "READY_FOR_REVIEW"}}],
            drafts=[{"id": "submission-draft"}],
        )
        result = self.publish(api)
        self.assertEqual(result["appStoreVersion"], "reused")
        self.assertEqual(api.made("POST", "/reviewSubmissions"), [])
        self.assertEqual(api.made("POST", "/reviewSubmissionItems"), [])
        self.assertEqual(len(api.made("PATCH", "/reviewSubmissions/submission-draft")), 1)

    def test_review_needs_an_export_compliance_answer(self):
        api = FakeConnect(compliance=None)
        with self.assertRaisesRegex(RuntimeError, "export compliance"):
            self.publish(api)
        self.assertEqual(api.made("POST", "/appStoreVersions"), [])

    def test_validate_only_checks_the_app_and_changes_nothing(self):
        api = FakeConnect()
        result = self.publish(api, validate_only=True)
        self.assertEqual(result["result"], "validated")
        self.assertEqual(self.altool_calls, ["--validate-app"])
        self.assertEqual([call[:2] for call in api.calls], [("GET", "/apps")])

    def test_the_app_must_carry_the_release_version(self):
        api = FakeConnect()
        with self.assertRaisesRegex(ValueError, "0.13.4, but the release is 0.13.5"):
            self.publish(api, expected_version="0.13.5")
        self.assertEqual(api.calls, [])
        with self.assertRaisesRegex(ValueError, "Unsupported release mode"):
            self.publish(api, release="production")

    def test_processing_failure_and_timeout_stop_the_release(self):
        api = FakeConnect()
        api.builds.append({"id": "build-bad", "marketing": "0.13.4",
                           "attributes": {"version": "70", "processingState": "INVALID"}})
        with self.assertRaisesRegex(RuntimeError, "could not process"):
            self.publish(api)

        waiting = FakeConnect()
        waiting.builds.append({"id": "build-slow", "marketing": "0.13.4",
                               "attributes": {"version": "70", "processingState": "PROCESSING"}})
        with self.assertRaisesRegex(RuntimeError, "still PROCESSING"):
            self.publish(waiting, processing_timeout=0)

    def test_altool_gets_the_key_folder_and_refuses_a_misnamed_key(self):
        with patch.object(store.subprocess, "run") as run:
            store.run_altool("--upload-app", self.ipa, "KEY123", "issuer-1", Path("/keys/AuthKey_KEY123.p8"))
        command = run.call_args.args[0]
        self.assertEqual(command, ["xcrun", "altool", "--upload-app", "-f", str(self.ipa), "-t", "ios",
                                   "--apiKey", "KEY123", "--apiIssuer", "issuer-1"])
        self.assertEqual(run.call_args.kwargs["env"]["API_PRIVATE_KEYS_DIR"], "/keys")
        self.assertTrue(run.call_args.kwargs["check"])
        with self.assertRaisesRegex(ValueError, "AuthKey_KEY123.p8"):
            store.run_altool("--upload-app", self.ipa, "KEY123", "issuer-1", Path("/keys/key.p8"))


class AppStoreWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / ".github/workflows/app-store.yml").read_text(encoding="utf-8")
        self.release = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.archive = self.workflow.split("\n  archive:\n", 1)[1].split("\n  publish:\n", 1)[0]
        self.publish = self.workflow.split("\n  publish:\n", 1)[1]

    def test_the_build_sees_no_secret_and_signing_runs_no_build(self):
        self.assertNotIn("secrets.", self.archive)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", self.archive)
        self.assertNotIn("github.repository == 'stevyhacker/LokalBot'", self.archive.split("    steps:", 1)[0])
        self.assertIn("if: github.event_name != 'pull_request' && github.repository == 'stevyhacker/LokalBot'",
                      self.publish.split("    steps:", 1)[0])
        self.assertIn("runs-on: macos-26", self.archive)
        self.assertIn("runs-on: macos-26", self.publish)
        for build_tool in ("xcodegen", "cargo", "lokalbot-sync", "xcodebuild archive", "brew "):
            self.assertNotIn(build_tool, self.publish, build_tool)
        self.assertIn("xcodebuild -exportArchive", self.publish)
        self.assertIn("-exportOptionsPlist Companion/ios/ExportOptions.plist", self.publish)
        self.assertIn("Scripts/release/publish_app_store.py", self.publish)
        self.assertEqual(self.publish.count("""trap 'rm -rf "$keys"' EXIT"""), 2)
        self.assertEqual(re.findall(r"runs-on: (\S+)", self.workflow), ["macos-26", "macos-26"])
        for line in self.workflow.splitlines():
            if line.strip().startswith("if:"):
                self.assertNotIn("secrets.", line)

    def test_a_release_call_is_told_apart_by_an_input_not_the_event_name(self):
        self.assertNotIn("'workflow_call'", self.workflow)
        call_inputs = self.workflow.split("  workflow_call:\n", 1)[1].split("  workflow_dispatch:\n", 1)[0]
        dispatch_inputs = self.workflow.split("  workflow_dispatch:\n", 1)[1].split("  pull_request:\n", 1)[0]
        self.assertIn("      from_release:\n", call_inputs)
        self.assertNotIn("from_release", dispatch_inputs)

    def test_export_options_sign_for_the_store_without_touching_the_build_number(self):
        options = plistlib.loads((ROOT / "Companion/ios/ExportOptions.plist").read_bytes())
        self.assertEqual(options, {
            "method": "app-store-connect",
            "destination": "export",
            "teamID": "3N8B4562P4",
            "signingStyle": "automatic",
            "manageAppVersionAndBuildNumber": False,
            "uploadSymbols": True,
        })
        project = (ROOT / "Companion/ios/project.yml").read_text(encoding="utf-8")
        self.assertIn(f"DEVELOPMENT_TEAM: {options['teamID']}", project)
        self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER: {BUNDLE_ID}", project)
        self.assertIn(BUNDLE_ID, self.archive)

    def test_an_unsigned_archive_carries_no_entitlements(self):
        project = (ROOT / "Companion/ios/project.yml").read_text(encoding="utf-8")
        self.assertNotIn("CODE_SIGN_ENTITLEMENTS", project)
        self.assertNotIn("entitlements:", project)

    def test_request_check_keeps_manual_runs_on_master_and_stable_tags(self):
        def check(**variables):
            return run_step(self.archive, "Check the request", **variables)

        self.assertEqual(check(TAG="v0.13.4", FROM_RELEASE="true", VALIDATE_ONLY="false",
                               GITHUB_REF="refs/tags/v0.13.4")[0], 0)
        self.assertEqual(check(TAG="v0.13.4", FROM_RELEASE="false", VALIDATE_ONLY="false",
                               GITHUB_REF="refs/heads/master")[0], 0)
        self.assertEqual(check(TAG="", FROM_RELEASE="false", VALIDATE_ONLY="true",
                               GITHUB_REF="refs/heads/master")[0], 0)
        code, _, printed = check(TAG="v0.13.4", FROM_RELEASE="false", VALIDATE_ONLY="false",
                                 GITHUB_REF="refs/heads/some-branch")
        self.assertNotEqual(code, 0)
        self.assertIn("dispatched from master", printed)
        code, _, printed = check(TAG="", FROM_RELEASE="false", VALIDATE_ONLY="false", GITHUB_REF="refs/heads/master")
        self.assertNotEqual(code, 0)
        self.assertIn("Name the stable tag", printed)
        code, _, printed = check(TAG="v0.13.4-beta.1", FROM_RELEASE="true", VALIDATE_ONLY="false",
                                 GITHUB_REF="refs/tags/v0.13.4-beta.1")
        self.assertNotEqual(code, 0)
        self.assertIn("pre-releases stay off the App Store", printed)

    def test_gate_needs_every_secret_and_resolves_the_release_mode(self):
        def gate(**variables):
            values = dict(INPUT_RELEASE="", APP_STORE_RELEASE_VAR="", APP_STORE_CONNECT_KEY_ID="KEY123",
                          APP_STORE_CONNECT_ISSUER_ID="issuer-1", APP_STORE_CONNECT_API_KEY="pem")
            values.update(variables)
            return run_step(self.publish, "Check credentials and release mode", **values)

        self.assertEqual(gate()[:2], (0, "release=review"))
        self.assertEqual(gate(INPUT_RELEASE="default")[:2], (0, "release=review"))
        self.assertEqual(gate(APP_STORE_RELEASE_VAR="testflight")[:2], (0, "release=testflight"))
        self.assertEqual(gate(INPUT_RELEASE="default", APP_STORE_RELEASE_VAR="manual")[:2], (0, "release=manual"))
        self.assertEqual(gate(INPUT_RELEASE="review", APP_STORE_RELEASE_VAR="testflight")[:2], (0, "release=review"))
        code, out, printed = gate(APP_STORE_RELEASE_VAR="production")
        self.assertNotEqual(code, 0)
        self.assertEqual(out, "")
        self.assertIn("Unknown release mode", printed)
        for secret in ("APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID", "APP_STORE_CONNECT_API_KEY"):
            code, _, printed = gate(**{secret: ""})
            self.assertNotEqual(code, 0, secret)
            self.assertIn(f"Missing required App Store secret: {secret}", printed)
        code, _, printed = gate(APP_STORE_CONNECT_KEY_ID="../KEY")
        self.assertNotEqual(code, 0)
        self.assertIn("letters and digits only", printed)

    def test_release_calls_the_workflow_only_when_switched_on_for_stable_tags(self):
        call = self.release.split("\n  ios-app-store:\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn("if: github.repository == 'stevyhacker/LokalBot' && github.event_name == 'push' && !contains(github.ref_name, '-') "
                      "&& vars.APP_STORE_PUBLISH == 'true'", call)
        self.assertIn("needs: release", call)
        self.assertIn("uses: ./.github/workflows/app-store.yml", call)
        self.assertIn("tag: ${{ github.ref_name }}", call)
        for secret in ("APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID", "APP_STORE_CONNECT_API_KEY"):
            self.assertIn(f"{secret}: ${{{{ secrets.{secret} }}}}", call)
            self.assertIn(f"      {secret}:\n        required: false", self.workflow)
        self.assertNotIn("contents: write", call)

    def test_the_app_follows_the_release_version(self):
        info = plistlib.loads((ROOT / "LokalBot/Info.plist").read_bytes())
        project = (ROOT / "Companion/ios/project.yml").read_text(encoding="utf-8")
        self.assertIn(f'MARKETING_VERSION: "{info["CFBundleShortVersionString"]}"', project)
        self.assertIn(f'CURRENT_PROJECT_VERSION: "{info["CFBundleVersion"]}"', project)

    def test_the_app_answers_export_compliance_itself(self):
        project = (ROOT / "Companion/ios/project.yml").read_text(encoding="utf-8")
        self.assertIn("        ITSAppUsesNonExemptEncryption: false\n", project)
        generated = plistlib.loads((ROOT / "Companion/ios/App/Info.plist").read_bytes())
        self.assertIs(generated["ITSAppUsesNonExemptEncryption"], False)


if __name__ == "__main__":
    unittest.main()
