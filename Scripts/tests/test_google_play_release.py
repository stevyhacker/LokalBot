"""Tests for Google Play App Bundle signing, API upload, and workflow wiring."""

from __future__ import annotations

import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "publish_google_play", ROOT / "Scripts/release/publish_google_play.py"
)
play = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(play)

SIGN_BUNDLE = ROOT / "Scripts/release/sign-android-bundle.sh"


def make_unsigned_aab(path: Path) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("BundleConfig.pb", b"bundle-config")
        archive.writestr("base/manifest/AndroidManifest.xml", b"manifest")


def make_signed_stub_aab(path: Path) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("BundleConfig.pb", b"bundle-config")
        archive.writestr("base/manifest/AndroidManifest.xml", b"manifest")
        archive.writestr("META-INF/UPLOAD.RSA", b"signature")


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


class ReleaseNotesAndGradleTests(unittest.TestCase):
    def test_format_release_notes_strips_markdown_and_caps_at_500_chars(self):
        md = (
            "## What’s new\n\n"
            "- **Apple Speech (Mac).** Choose **Apple Speech** in [Settings](https://example.com) and run `lokalbot-cli`.\n"
            "<!-- no explainer: small addition -->\n\n"
            "## Improvements\n\n"
            + "- **Fast search.** " + ("Details about improvements across platforms. " * 20)
            + "\n\n**Full changelog:** https://github.com/stevyhacker/lokalbot/compare/v0.13.2...v0.13.3\n"
        )
        formatted = play.format_release_notes(md, "0.13.3")
        self.assertLessEqual(len(formatted), 500)
        self.assertNotIn("no explainer", formatted)
        self.assertNotIn("Full changelog", formatted)
        self.assertNotIn("https://example.com", formatted)
        self.assertNotIn("**", formatted)
        self.assertNotIn("`", formatted)
        self.assertIn("• Apple Speech (Mac).", formatted)
        self.assertTrue(formatted.endswith("…"))

    def test_format_release_notes_empty_fallback(self):
        formatted = play.format_release_notes("<!-- comment only -->", "0.13.4")
        self.assertIn("0.13.4", formatted)
        self.assertLessEqual(len(formatted), 500)

    def test_read_gradle_version_reads_companion_app(self):
        pkg, code, name = play.read_gradle_version(ROOT / "Companion/android/app/build.gradle.kts")
        self.assertEqual(pkg, "me.dotenv.lokalbot.companion")
        self.assertGreater(code, 0)
        self.assertRegex(name, r"^\d+\.\d+\.\d+$")

    def test_validate_aab_archive_rejects_unsigned_and_non_aab(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            unsigned = root / "unsigned.aab"
            make_unsigned_aab(unsigned)
            with self.assertRaises(ValueError):
                play.validate_aab_archive(unsigned)

            not_aab = root / "other.zip"
            with zipfile.ZipFile(not_aab, "w") as archive:
                archive.writestr("META-INF/UPLOAD.RSA", b"sig")
            with self.assertRaises(ValueError):
                play.validate_aab_archive(not_aab)

            signed = root / "signed.aab"
            make_signed_stub_aab(signed)
            play.validate_aab_archive(signed)


@unittest.skipUnless(
    shutil.which("keytool") and shutil.which("jarsigner"),
    "JDK keytool/jarsigner required",
)
class BundleSigningScriptTests(unittest.TestCase):
    def _gen_key(self, keystore: Path, alias: str, storepass: str, keypass: str | None = None,
                 storetype: str = "PKCS12") -> str:
        cmd = [
            "keytool", "-genkeypair",
            "-keystore", str(keystore),
            "-storetype", storetype,
            "-storepass", storepass,
            "-alias", alias,
            "-keyalg", "RSA",
            "-keysize", "2048",
            "-validity", "1",
            "-dname", f"CN={alias}",
        ]
        if keypass is not None:
            cmd.extend(["-keypass", keypass])
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        listing = subprocess.check_output(
            ["keytool", "-list", "-v", "-keystore", str(keystore), "-storepass", storepass, "-alias", alias],
            text=True,
            stderr=subprocess.DEVNULL,
            env=dict(os.environ, LC_ALL="C"),
        )
        match = re.search(r"SHA256:\s*([0-9A-Fa-f:]+)", listing)
        self.assertIsNotNone(match)
        return match.group(1).replace(":", "").lower()

    def test_signs_auto_detected_alias_and_enforces_certificate_pin(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            keystore = root / "upload.p12"
            digest = self._gen_key(keystore, "upload", "store-secret")
            unsigned = root / "app-release.aab"
            signed = root / "signed.aab"
            refused = root / "refused.aab"
            make_unsigned_aab(unsigned)

            env = dict(os.environ, PLAY_UPLOAD_KEYSTORE_PASSWORD="store-secret")
            done = subprocess.run(
                [str(SIGN_BUNDLE), str(unsigned), str(signed), str(keystore), digest],
                capture_output=True, text=True, env=env,
            )
            self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
            self.assertIn(digest, done.stdout)
            play.validate_aab_archive(signed)

            wrong = subprocess.run(
                [str(SIGN_BUNDLE), str(unsigned), str(refused), str(keystore), "0" * 64],
                capture_output=True, text=True, env=env,
            )
            self.assertNotEqual(wrong.returncode, 0)
            self.assertFalse(refused.exists())

    def test_requires_alias_when_multiple_entries_exist_and_supports_separate_keypass(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            keystore = root / "upload.jks"
            self._gen_key(keystore, "first", "store-secret", keypass="key-one", storetype="JKS")
            digest2 = self._gen_key(keystore, "second", "store-secret", keypass="key-two", storetype="JKS")
            unsigned = root / "app-release.aab"
            signed = root / "signed.aab"
            make_unsigned_aab(unsigned)

            base_env = dict(os.environ, PLAY_UPLOAD_KEYSTORE_PASSWORD="store-secret")
            ambiguous = subprocess.run(
                [str(SIGN_BUNDLE), str(unsigned), str(signed), str(keystore)],
                capture_output=True, text=True, env=base_env,
            )
            self.assertNotEqual(ambiguous.returncode, 0)
            self.assertFalse(signed.exists())

            explicit_env = dict(
                base_env,
                PLAY_UPLOAD_KEY_ALIAS="second",
                PLAY_UPLOAD_KEY_PASSWORD="key-two",
            )
            ok = subprocess.run(
                [str(SIGN_BUNDLE), str(unsigned), str(signed), str(keystore), digest2],
                capture_output=True, text=True, env=explicit_env,
            )
            self.assertEqual(ok.returncode, 0, ok.stderr + ok.stdout)
            play.validate_aab_archive(signed)


class GooglePlayAuthTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("openssl"), "openssl required")
    def test_service_account_jwt_signature_verifies_with_public_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            priv = root / "key.pem"
            pub = root / "pub.pem"
            subprocess.run(["openssl", "genrsa", "-out", str(priv), "2048"], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["openssl", "rsa", "-in", str(priv), "-pubout", "-out", str(pub)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            captured = {}

            def fake_http(method, url, *, headers=None, body=None, content_type=None, timeout=300):
                captured["method"] = method
                captured["url"] = url
                captured["body"] = urllib.parse.parse_qs(body.decode("ascii"))
                return {"access_token": "ya29.test-token"}

            sa = {
                "client_email": "play@example.iam.gserviceaccount.com",
                "private_key": priv.read_text(encoding="utf-8"),
                "token_uri": "https://oauth2.googleapis.com/token",
            }
            with patch.object(play, "http_json", side_effect=fake_http):
                token = play.token_from_service_account(sa, now=1700000000)

            self.assertEqual(token, "ya29.test-token")
            assertion = captured["body"]["assertion"][0]
            header_b64, claims_b64, sig_b64 = assertion.split(".")
            claims = json.loads(base64.urlsafe_b64decode(claims_b64 + "==").decode("utf-8"))
            self.assertEqual(claims["iss"], sa["client_email"])
            self.assertEqual(claims["scope"], play.ANDROID_PUBLISHER_SCOPE)
            self.assertEqual(claims["exp"], 1700003600)

            sig_file = root / "sig.bin"
            sig_file.write_bytes(base64.urlsafe_b64decode(sig_b64 + "=="))
            verify = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", str(pub), "-signature", str(sig_file)],
                input=f"{header_b64}.{claims_b64}".encode("ascii"),
                capture_output=True,
            )
            self.assertEqual(verify.returncode, 0, verify.stderr.decode("utf-8", errors="replace"))

    def test_github_oidc_exchanges_token_via_sts_and_iam(self):
        calls = []

        def fake_http(method, url, *, headers=None, body=None, content_type=None, timeout=300):
            calls.append((method, url, headers, body))
            if url.startswith("https://oidc.example/token"):
                return {"value": "gh-oidc-jwt"}
            if url == play.STS_TOKEN_URL:
                return {"access_token": "sts-federated-token"}
            if "generateAccessToken" in url:
                return {"accessToken": "ya29.oidc-token"}
            raise AssertionError(url)

        provider = "projects/123456/locations/global/workloadIdentityPools/gh/providers/repo"
        with patch.object(play, "http_json", side_effect=fake_http):
            token = play.token_from_github_oidc(
                provider,
                "play@example.iam.gserviceaccount.com",
                request_url="https://oidc.example/token?api=1",
                request_token="gh-bearer",
            )
        self.assertEqual(token, "ya29.oidc-token")
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[1][3]["audience"], f"//iam.googleapis.com/{provider}")
        self.assertEqual(calls[1][3]["subjectToken"], "gh-oidc-jwt")
        self.assertEqual(calls[2][3]["scope"], [play.ANDROID_PUBLISHER_SCOPE])

        with self.assertRaises(ValueError):
            play.token_from_github_oidc("not-a-provider", "a@b.c", request_url="u", request_token="t")


class PublishBundleFlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.aab = self.root / "LokalBot-0.13.3-android.aab"
        make_signed_stub_aab(self.aab)
        self.mapping = self.root / "mapping.txt"
        self.mapping.write_text("com.example.A -> a:\n", encoding="utf-8")

    def test_full_publish_uploads_bundle_mapping_track_and_commits(self):
        calls = []

        def fake_http(method, url, *, headers=None, body=None, content_type=None, timeout=300):
            calls.append((method, url, body))
            if method == "POST" and url.endswith("/edits"):
                return {"id": "edit-1"}
            if method == "GET" and "/tracks/" in url:
                return {"track": "production", "releases": [{"versionCodes": ["68"], "status": "completed"}]}
            if method == "GET" and url.endswith("/bundles"):
                return {"bundles": [{"versionCode": 68}]}
            if method == "POST" and "/bundles?uploadType=media" in url:
                return {"versionCode": 69, "sha256": "abc"}
            if method == "POST" and "/deobfuscationFiles/proguard" in url:
                return {}
            if method == "PUT" and "/tracks/production" in url:
                return body
            if method == "POST" and url.endswith(":commit"):
                return {"id": "edit-1"}
            raise AssertionError((method, url))

        with patch.object(play, "http_json", side_effect=fake_http):
            result = play.publish_bundle(
                access_token="tok",
                package_name="me.dotenv.lokalbot.companion",
                aab_path=self.aab,
                version_code=69,
                version_name="0.13.3",
                track="production",
                status="completed",
                release_notes="Short notes",
                mapping_path=self.mapping,
            )

        self.assertEqual(result["result"], "committed")
        self.assertTrue(result["uploadedBundle"])
        self.assertTrue(result["uploadedMapping"])
        self.assertEqual(
            [m for m, _, _ in calls],
            ["POST", "GET", "GET", "POST", "POST", "PUT", "POST"],
        )
        track_put = calls[5][2]
        self.assertEqual(track_put["releases"][0]["versionCodes"], ["69"])
        self.assertEqual(track_put["releases"][0]["status"], "completed")
        self.assertEqual(track_put["releases"][0]["releaseNotes"][0]["text"], "Short notes")

    def test_skips_cleanly_when_version_code_is_already_on_track(self):
        calls = []

        def fake_http(method, url, *, headers=None, body=None, content_type=None, timeout=300):
            calls.append((method, url))
            if method == "POST" and url.endswith("/edits"):
                return {"id": "edit-2"}
            if method == "GET" and "/tracks/production" in url:
                return {"track": "production", "releases": [{"versionCodes": ["69"], "status": "completed"}]}
            if method == "DELETE" and url.endswith("/edits/edit-2"):
                return {}
            raise AssertionError((method, url))

        with patch.object(play, "http_json", side_effect=fake_http):
            result = play.publish_bundle(
                access_token="tok",
                package_name="me.dotenv.lokalbot.companion",
                aab_path=self.aab,
                version_code=69,
                version_name="0.13.3",
                track="production",
                status="completed",
                release_notes="Short notes",
                mapping_path=self.mapping,
            )

        self.assertEqual(result["result"], "already_published")
        self.assertEqual([m for m, _ in calls], ["POST", "GET", "DELETE"])

    def test_resumes_without_reuploading_when_bundle_already_exists_in_edit(self):
        calls = []

        def fake_http(method, url, *, headers=None, body=None, content_type=None, timeout=300):
            calls.append((method, url))
            if method == "POST" and url.endswith("/edits"):
                return {"id": "edit-3"}
            if method == "GET" and "/tracks/internal" in url:
                return {}
            if method == "GET" and url.endswith("/bundles"):
                return {"bundles": [{"versionCode": 69}]}
            if method == "PUT" and "/tracks/internal" in url:
                return {}
            if method == "POST" and url.endswith(":commit"):
                return {}
            raise AssertionError((method, url))

        with patch.object(play, "http_json", side_effect=fake_http):
            result = play.publish_bundle(
                access_token="tok",
                package_name="me.dotenv.lokalbot.companion",
                aab_path=self.aab,
                version_code=69,
                version_name="0.13.3",
                track="internal",
                status="draft",
                release_notes="Notes",
            )

        self.assertEqual(result["result"], "committed")
        self.assertFalse(result["uploadedBundle"])
        self.assertFalse(any("/bundles?uploadType=media" in url for _, url in calls))

    def test_validate_only_validates_and_deletes_without_committing(self):
        calls = []

        def fake_http(method, url, *, headers=None, body=None, content_type=None, timeout=300):
            calls.append((method, url))
            if method == "POST" and url.endswith("/edits"):
                return {"id": "edit-3"}
            if method == "GET" and "/tracks/internal" in url:
                return {}
            if method == "GET" and url.endswith("/bundles"):
                return {"bundles": [{"versionCode": 69}]}
            if method == "PUT" and "/tracks/internal" in url:
                return {}
            if method == "POST" and url.endswith(":validate"):
                return {}
            if method == "DELETE" and url.endswith("/edits/edit-3"):
                return {}
            raise AssertionError((method, url))

        with patch.object(play, "http_json", side_effect=fake_http):
            result = play.publish_bundle(
                access_token="tok",
                package_name="me.dotenv.lokalbot.companion",
                aab_path=self.aab,
                version_code=69,
                version_name="0.13.3",
                track="internal",
                status="draft",
                release_notes="Notes",
                validate_only=True,
            )
        self.assertEqual(result["result"], "validated")
        self.assertFalse(result["uploadedBundle"])
        self.assertTrue(any(url.endswith(":validate") for _, url in calls))
        self.assertTrue(any(m == "DELETE" for m, _ in calls))
        self.assertFalse(any(url.endswith(":commit") for _, url in calls))

    def test_version_code_mismatch_deletes_edit_and_fails(self):
        deleted = []

        def fake_http(method, url, *, headers=None, body=None, content_type=None, timeout=300):
            if method == "POST" and url.endswith("/edits"):
                return {"id": "edit-4"}
            if method == "GET" and "/tracks/" in url:
                return {}
            if method == "GET" and url.endswith("/bundles"):
                return {"bundles": []}
            if method == "POST" and "/bundles?uploadType=media" in url:
                return {"versionCode": 70}
            if method == "DELETE" and url.endswith("/edits/edit-4"):
                deleted.append(url)
                return {}
            raise AssertionError((method, url))

        with patch.object(play, "http_json", side_effect=fake_http):
            with self.assertRaises(RuntimeError):
                play.publish_bundle(
                    access_token="tok",
                    package_name="me.dotenv.lokalbot.companion",
                    aab_path=self.aab,
                    version_code=69,
                    version_name="0.13.3",
                    track="production",
                    status="completed",
                    release_notes="Notes",
                )
        self.assertEqual(len(deleted), 1)

    def test_rollout_fraction_validation(self):
        with self.assertRaises(ValueError):
            play.publish_bundle(
                access_token="tok",
                package_name="me.dotenv.lokalbot.companion",
                aab_path=self.aab,
                version_code=69,
                version_name="0.13.3",
                track="production",
                status="inProgress",
                release_notes="Notes",
            )
        with self.assertRaises(ValueError):
            play.publish_bundle(
                access_token="tok",
                package_name="me.dotenv.lokalbot.companion",
                aab_path=self.aab,
                version_code=69,
                version_name="0.13.3",
                track="production",
                status="completed",
                release_notes="Notes",
                user_fraction=0.5,
            )


class GooglePlayWorkflowBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.play_wf = (ROOT / ".github/workflows/google-play.yml").read_text(encoding="utf-8")
        self.android_wf = (ROOT / ".github/workflows/companion-android.yml").read_text(encoding="utf-8")
        self.release_wf = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    def test_upload_certificate_pin_matches_docs(self):
        pin = (ROOT / "Companion/android/play-upload-certificate.sha256").read_text(encoding="utf-8").strip()
        self.assertRegex(pin, r"^[0-9a-f]{64}$")
        doc = (ROOT / "Docs/releasing/android.md").read_text(encoding="utf-8")
        colonized = ":".join(pin[i:i + 2].upper() for i in range(0, len(pin), 2))
        self.assertIn(colonized, doc)

    def test_companion_android_builds_bundle_without_play_secrets(self):
        self.assertIn(":app:bundleRelease", self.android_wf)
        self.assertIn("Scripts/release/sign-android-bundle.sh", self.android_wf)
        self.assertIn("Companion/android/app/build/outputs/bundle/release/app-release.aab", self.android_wf)
        for secret in ("PLAY_UPLOAD_KEYSTORE_BASE64", "PLAY_SERVICE_ACCOUNT_JSON", "PLAY_WORKLOAD_IDENTITY_PROVIDER"):
            self.assertNotIn(secret, self.android_wf)

    def test_google_play_workflow_isolates_secrets_and_gates_publication(self):
        for line in self.play_wf.splitlines():
            if line.strip().startswith("if:"):
                self.assertNotIn("secrets.", line)

        bundle_job = self.play_wf.split("\n  bundle:\n", 1)[1].split("\n  publish:\n", 1)[0]
        self.assertNotIn("secrets.", bundle_job)
        self.assertIn("runs-on: ubuntu-24.04", bundle_job)

        publish_job = self.play_wf.split("\n  publish:\n", 1)[1]
        self.assertIn("github.repository == 'stevyhacker/LokalBot'", publish_job.split("    steps:", 1)[0])
        check_job = self.play_wf.split("\n  check:\n", 1)[1].split("\n  bundle:\n", 1)[0]
        self.assertNotIn("github.repository == 'stevyhacker/LokalBot'", check_job.split("    steps:", 1)[0])
        self.assertIn("runs-on: ubuntu-24.04", publish_job)
        self.assertIn("Companion/android/play-upload-certificate.sha256", publish_job)
        self.assertIn("Scripts/release/sign-android-bundle.sh", publish_job)
        self.assertIn("Scripts/release/publish_google_play.py", publish_job)

        code, out, printed = run_step(
            publish_job,
            "Check tag, switch and credentials",
            TAG="v0.13.4",
            FROM_RELEASE="true",
            GITHUB_REF="refs/tags/v0.13.4",
            PLAY_PUBLISH="",
            PLAY_TRACK_VAR="",
            PLAY_STATUS_VAR="",
            INPUT_TRACK="",
            INPUT_STATUS="",
            PLAY_UPLOAD_KEYSTORE_BASE64="",
            PLAY_UPLOAD_KEYSTORE_PASSWORD="",
            PLAY_SERVICE_ACCOUNT_JSON="",
            PLAY_WORKLOAD_IDENTITY_PROVIDER="",
            PLAY_SERVICE_ACCOUNT_EMAIL="",
        )
        self.assertEqual((code, out), (0, "publish=false"))
        self.assertIn("::notice::", printed)

        code, out, printed = run_step(
            publish_job,
            "Check tag, switch and credentials",
            TAG="v0.13.4",
            FROM_RELEASE="true",
            GITHUB_REF="refs/tags/v0.13.4",
            PLAY_PUBLISH="true",
            PLAY_TRACK_VAR="",
            PLAY_STATUS_VAR="",
            INPUT_TRACK="",
            INPUT_STATUS="",
            PLAY_UPLOAD_KEYSTORE_BASE64="",
            PLAY_UPLOAD_KEYSTORE_PASSWORD="",
            PLAY_SERVICE_ACCOUNT_JSON="",
            PLAY_WORKLOAD_IDENTITY_PROVIDER="",
            PLAY_SERVICE_ACCOUNT_EMAIL="",
        )
        self.assertNotEqual(code, 0)
        self.assertIn("::error::", printed)

        code, out, _ = run_step(
            publish_job,
            "Check tag, switch and credentials",
            TAG="v0.13.4-beta.1",
            FROM_RELEASE="true",
            GITHUB_REF="refs/tags/v0.13.4-beta.1",
            PLAY_PUBLISH="true",
            PLAY_TRACK_VAR="",
            PLAY_STATUS_VAR="",
            INPUT_TRACK="",
            INPUT_STATUS="",
            PLAY_UPLOAD_KEYSTORE_BASE64="x",
            PLAY_UPLOAD_KEYSTORE_PASSWORD="x",
            PLAY_SERVICE_ACCOUNT_JSON="{}",
            PLAY_WORKLOAD_IDENTITY_PROVIDER="",
            PLAY_SERVICE_ACCOUNT_EMAIL="",
        )
        self.assertNotEqual(code, 0)

        code, out, _ = run_step(
            publish_job,
            "Check tag, switch and credentials",
            TAG="v0.13.4",
            FROM_RELEASE="true",
            GITHUB_REF="refs/tags/v0.13.4",
            PLAY_PUBLISH="true",
            PLAY_TRACK_VAR="",
            PLAY_STATUS_VAR="",
            INPUT_TRACK="",
            INPUT_STATUS="",
            PLAY_UPLOAD_KEYSTORE_BASE64="x",
            PLAY_UPLOAD_KEYSTORE_PASSWORD="x",
            PLAY_SERVICE_ACCOUNT_JSON="{}",
            PLAY_WORKLOAD_IDENTITY_PROVIDER="",
            PLAY_SERVICE_ACCOUNT_EMAIL="",
        )
        self.assertEqual(code, 0)
        self.assertIn("publish=true", out)
        self.assertIn("auth_mode=service_account_json", out)
        self.assertIn("track=production", out)
        self.assertIn("status=completed", out)

        code, out, _ = run_step(
            publish_job,
            "Check tag, switch and credentials",
            TAG="v0.13.4",
            FROM_RELEASE="true",
            GITHUB_REF="refs/tags/v0.13.4",
            PLAY_PUBLISH="true",
            PLAY_TRACK_VAR="internal",
            PLAY_STATUS_VAR="draft",
            INPUT_TRACK="",
            INPUT_STATUS="",
            PLAY_UPLOAD_KEYSTORE_BASE64="x",
            PLAY_UPLOAD_KEYSTORE_PASSWORD="x",
            PLAY_SERVICE_ACCOUNT_JSON="",
            PLAY_WORKLOAD_IDENTITY_PROVIDER="projects/1/locations/global/workloadIdentityPools/p/providers/g",
            PLAY_SERVICE_ACCOUNT_EMAIL="sa@example.iam.gserviceaccount.com",
        )
        self.assertEqual(code, 0)
        self.assertIn("auth_mode=github_oidc", out)
        self.assertIn("track=internal", out)
        self.assertIn("status=draft", out)

    def test_upload_step_exits_with_the_publisher_status_in_both_sign_in_modes(self):
        publish_job = self.play_wf.split("\n  publish:\n", 1)[1]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tools = root / "bin"
            tools.mkdir()
            runner_temp = root / "runner"
            runner_temp.mkdir()
            fake_python = tools / "python3"
            fake_python.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$RUNNER_TEMP/args"\nexit "${FAKE_EXIT:-0}"\n')
            fake_python.chmod(0o755)
            base = dict(
                TAG="v0.13.4",
                PLAY_TRACK="production",
                PLAY_STATUS="completed",
                VALIDATE_ONLY="true",
                RUNNER_TEMP=str(runner_temp),
                PATH=f"{tools}{os.pathsep}{os.environ['PATH']}",
            )
            keyless = dict(
                base,
                AUTH_MODE="github_oidc",
                PLAY_SERVICE_ACCOUNT_JSON="",
                PLAY_WORKLOAD_IDENTITY_PROVIDER="projects/1/locations/global/workloadIdentityPools/p/providers/g",
                PLAY_SERVICE_ACCOUNT_EMAIL="sa@example.iam.gserviceaccount.com",
            )
            code, _, printed = run_step(publish_job, "Upload App Bundle and R8 mapping to Google Play", **keyless)
            self.assertEqual(code, 0, printed)
            args = (runner_temp / "args").read_text()
            self.assertIn("--workload-identity-provider", args)
            self.assertIn("--validate-only", args)
            self.assertNotIn("--service-account-file", args)

            code, _, _ = run_step(publish_job, "Upload App Bundle and R8 mapping to Google Play",
                                  **dict(keyless, FAKE_EXIT="3"))
            self.assertEqual(code, 3)

            with_key = dict(
                base,
                AUTH_MODE="service_account_json",
                PLAY_SERVICE_ACCOUNT_JSON="{}",
                PLAY_WORKLOAD_IDENTITY_PROVIDER="",
                PLAY_SERVICE_ACCOUNT_EMAIL="",
            )
            code, _, printed = run_step(publish_job, "Upload App Bundle and R8 mapping to Google Play", **with_key)
            self.assertEqual(code, 0, printed)
            self.assertIn("--service-account-file", (runner_temp / "args").read_text())
            self.assertFalse((runner_temp / "play-service-account.json").exists())

    def test_release_call_is_told_apart_by_an_input_not_the_event_name(self):
        self.assertNotIn("'workflow_call'", self.play_wf)
        self.assertNotIn('"workflow_call"', self.play_wf)
        call_inputs = self.play_wf.split("  workflow_call:\n", 1)[1].split("  workflow_dispatch:\n", 1)[0]
        dispatch_inputs = self.play_wf.split("  workflow_dispatch:\n", 1)[1].split("  pull_request:\n", 1)[0]
        self.assertIn("      from_release:\n", call_inputs)
        self.assertNotIn("from_release", dispatch_inputs)
        publish_job = self.play_wf.split("\n  publish:\n", 1)[1]
        self.assertIn("(inputs.from_release == true || needs.bundle.result == 'success')", publish_job)

        code, out, printed = run_step(
            publish_job,
            "Check tag, switch and credentials",
            TAG="v0.13.4",
            FROM_RELEASE="false",
            GITHUB_REF="refs/heads/some-branch",
            PLAY_PUBLISH="true",
            PLAY_TRACK_VAR="",
            PLAY_STATUS_VAR="",
            INPUT_TRACK="",
            INPUT_STATUS="",
            PLAY_UPLOAD_KEYSTORE_BASE64="x",
            PLAY_UPLOAD_KEYSTORE_PASSWORD="x",
            PLAY_SERVICE_ACCOUNT_JSON="{}",
            PLAY_WORKLOAD_IDENTITY_PROVIDER="",
            PLAY_SERVICE_ACCOUNT_EMAIL="",
        )
        self.assertNotEqual(code, 0)
        self.assertIn("must run from master", printed)

    def test_release_workflow_wires_google_play_and_keeps_downstream_linux_windows_jobs_running(self):
        play_call = self.release_wf.split("\n  android-play:\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn("if: github.repository == 'stevyhacker/LokalBot' && github.event_name == 'push' && !contains(github.ref_name, '-')", play_call)
        self.assertIn("needs: [release, android]", play_call)
        self.assertIn("uses: ./.github/workflows/google-play.yml", play_call)
        self.assertIn("id-token: write", play_call)

        for job in ("linux-repos", "aur", "winget"):
            block = self.release_wf.split(f"\n  {job}:\n", 1)[1].split("\n\n", 1)[0]
            self.assertIn("always()", block, job)
            self.assertIn("needs.linux-windows-publish.result == 'success'", block, job)


if __name__ == "__main__":
    unittest.main()
