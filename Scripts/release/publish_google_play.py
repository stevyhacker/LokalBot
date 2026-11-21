#!/usr/bin/env python3
"""Upload a signed Android App Bundle (.aab) to Google Play via Android Publisher API v3.

Uses only the Python standard library (plus `openssl` for RS256 JWT signing when
authenticating with a service account JSON key). Supports two auth modes:

1. Service account JSON (`--service-account-file PATH`): signs an OAuth2 JWT
   assertion locally and exchanges it for an Android Publisher access token.
2. GitHub OIDC + GCP Workload Identity Federation (`--workload-identity-provider`
   and `--service-account-email`): exchanges the GitHub Actions OIDC token via
   Google STS and mints a short-lived access token via IAM Credentials.

Idempotent: if the target `versionCode` is already published on the requested
track, the edit is discarded and the script exits 0 without failing.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
CLOUD_PLATFORM_SCOPE = "https://www.googleapis.com/auth/cloud-platform"
DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token"
API_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_BASE = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
STS_TOKEN_URL = "https://sts.googleapis.com/v1/token"
IAM_CREDENTIALS_BASE = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts"

PLAY_NOTES_LIMIT = 500
VALID_STATUSES = ("completed", "draft", "halted", "inProgress")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def format_release_notes(markdown: str, version: str, *, limit: int = PLAY_NOTES_LIMIT) -> str:
    """Turn GitHub Release markdown into plain text fitting Google Play's 500-char cap."""
    text = re.sub(r"<!--.*?-->", "", markdown, flags=re.DOTALL)
    lines: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("**Full changelog:**"):
            continue
        if line.startswith("#"):
            heading = re.sub(r"^#+\s*", "", line).strip()
            if heading:
                lines.append(heading)
            continue
        # Convert markdown links `[label](url)` -> `label`, drop bold/code markers.
        line = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line)
        line = re.sub(r"\*\*([^*]+)\*\*", r"\1", line)
        line = line.replace("`", "")
        if line.startswith("- "):
            line = "• " + line[2:].strip()
        lines.append(line)

    combined = "\n".join(lines).strip()
    if not combined:
        combined = f"LokalBot {version} — see GitHub Releases for the full changelog."
    if len(combined) <= limit:
        return combined

    cutoff = limit - 1
    trimmed = combined[:cutoff]
    # Prefer cutting cleanly at a newline or space when it keeps most of the text.
    nl = trimmed.rfind("\n")
    if nl >= int(limit * 0.6):
        return trimmed[:nl].rstrip() + "…"
    sp = trimmed.rfind(" ")
    if sp >= int(limit * 0.7):
        return trimmed[:sp].rstrip(" ,;:-") + "…"
    return trimmed.rstrip() + "…"


def read_gradle_version(gradle_path: Path) -> tuple[str, int, str]:
    """Read (applicationId, versionCode, versionName) from app/build.gradle.kts."""
    source = gradle_path.read_text(encoding="utf-8")
    app_id = re.findall(r'^\s+applicationId\s*=\s*"([^"]+)"', source, re.MULTILINE)
    version_code = re.findall(r"^\s+versionCode\s*=\s*(\d+)", source, re.MULTILINE)
    version_name = re.findall(r'^\s+versionName\s*=\s*"([^"]+)"', source, re.MULTILINE)
    if len(app_id) != 1 or len(version_code) != 1 or len(version_name) != 1:
        raise ValueError(f"Could not uniquely read applicationId/versionCode/versionName from {gradle_path}")
    return app_id[0], int(version_code[0]), version_name[0]


def validate_aab_archive(aab_path: Path) -> None:
    """Verify the file is a signed Android App Bundle zip before uploading."""
    if not aab_path.is_file():
        raise ValueError(f"Bundle not found: {aab_path}")
    with zipfile.ZipFile(aab_path, "r") as archive:
        names = set(archive.namelist())
    if "BundleConfig.pb" not in names or "base/manifest/AndroidManifest.xml" not in names:
        raise ValueError(f"{aab_path} is not a valid Android App Bundle (missing BundleConfig.pb or manifest)")
    has_sig = any(name.startswith("META-INF/") and name.endswith((".RSA", ".DSA", ".EC")) for name in names)
    if not has_sig:
        raise ValueError(f"{aab_path} does not appear to be signed (no META-INF signature block)")


def http_json(
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    body: bytes | dict | None = None,
    content_type: str | None = None,
    timeout: int = 300,
) -> dict:
    req_headers = dict(headers or {})
    data: bytes | None
    if isinstance(body, dict):
        data = json.dumps(body).encode("utf-8")
        req_headers.setdefault("Content-Type", "application/json; charset=utf-8")
    else:
        data = body
        if content_type:
            req_headers["Content-Type"] = content_type
    request = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            if not raw:
                return {}
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {error.code} from {method} {url}: {detail}") from error


def sign_rs256(signing_input: bytes, private_key_pem: str) -> bytes:
    """Sign JWT bytes with RSASSA-PKCS1-v1_5 + SHA-256 using openssl."""
    fd, key_path = tempfile.mkstemp(prefix="play-sa-", suffix=".pem")
    try:
        os.chmod(key_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(private_key_pem)
        return subprocess.check_output(
            ["openssl", "dgst", "-sha256", "-sign", key_path],
            input=signing_input,
        )
    finally:
        try:
            os.unlink(key_path)
        except OSError:
            pass


def token_from_service_account(service_account: dict, *, now: int | None = None) -> str:
    client_email = service_account["client_email"]
    private_key = service_account["private_key"]
    token_uri = service_account.get("token_uri") or DEFAULT_TOKEN_URI
    issued = int(time.time()) if now is None else now
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode("utf-8"))
    claims = b64url(
        json.dumps(
            {
                "iss": client_email,
                "scope": ANDROID_PUBLISHER_SCOPE,
                "aud": token_uri,
                "iat": issued,
                "exp": issued + 3600,
            },
            separators=(",", ":"),
        ).encode("utf-8")
    )
    signing_input = f"{header}.{claims}".encode("ascii")
    signature = b64url(sign_rs256(signing_input, private_key))
    assertion = f"{header}.{claims}.{signature}"
    payload = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }
    ).encode("ascii")
    response = http_json(
        "POST",
        token_uri,
        body=payload,
        content_type="application/x-www-form-urlencoded",
    )
    access_token = response.get("access_token")
    if not access_token:
        raise RuntimeError(f"OAuth token response missing access_token: {response}")
    return access_token


def token_from_github_oidc(
    workload_identity_provider: str,
    service_account_email: str,
    *,
    request_url: str | None = None,
    request_token: str | None = None,
) -> str:
    provider = workload_identity_provider.strip().lstrip("/")
    if not provider.startswith("projects/"):
        raise ValueError(
            "Workload Identity Provider must have the form "
            "projects/<number>/locations/global/workloadIdentityPools/<pool>/providers/<provider>"
        )
    oidc_url = request_url or os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL", "")
    oidc_bearer = request_token or os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")
    if not oidc_url or not oidc_bearer:
        raise RuntimeError(
            "GitHub OIDC environment variables (ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN) are missing; "
            "ensure the job grants `id-token: write`."
        )
    audience = f"https://iam.googleapis.com/{provider}"
    sep = "&" if "?" in oidc_url else "?"
    oidc_response = http_json(
        "GET",
        f"{oidc_url}{sep}{urllib.parse.urlencode({'audience': audience})}",
        headers={"Authorization": f"Bearer {oidc_bearer}"},
    )
    subject_token = oidc_response.get("value")
    if not subject_token:
        raise RuntimeError("GitHub OIDC token response missing 'value'")

    sts_response = http_json(
        "POST",
        STS_TOKEN_URL,
        body={
            "audience": f"//iam.googleapis.com/{provider}",
            "grantType": "urn:ietf:params:oauth:grant-type:token-exchange",
            "requestedTokenType": "urn:ietf:params:oauth:token-type:access_token",
            "scope": CLOUD_PLATFORM_SCOPE,
            "subjectTokenType": "urn:ietf:params:oauth:token-type:jwt",
            "subjectToken": subject_token,
        },
    )
    federated_token = sts_response.get("access_token")
    if not federated_token:
        raise RuntimeError("Google STS token exchange response missing access_token")

    sa_quoted = urllib.parse.quote(service_account_email.strip(), safe="")
    iam_response = http_json(
        "POST",
        f"{IAM_CREDENTIALS_BASE}/{sa_quoted}:generateAccessToken",
        headers={"Authorization": f"Bearer {federated_token}"},
        body={"scope": [ANDROID_PUBLISHER_SCOPE], "lifetime": "1800s"},
    )
    access_token = iam_response.get("accessToken")
    if not access_token:
        raise RuntimeError("IAM generateAccessToken response missing accessToken")
    return access_token


def track_has_version_code(track_data: dict, version_code: int) -> bool:
    target = str(version_code)
    for release in track_data.get("releases") or []:
        codes = [str(code) for code in (release.get("versionCodes") or [])]
        if target in codes:
            return True
    return False


def publish_bundle(
    *,
    access_token: str,
    package_name: str,
    aab_path: Path,
    version_code: int,
    version_name: str,
    track: str,
    status: str,
    release_notes: str,
    mapping_path: Path | None = None,
    user_fraction: float | None = None,
    validate_only: bool = False,
    changes_not_sent_for_review: bool = False,
) -> dict:
    if status not in VALID_STATUSES:
        raise ValueError(f"Unsupported release status {status!r}; expected one of {', '.join(VALID_STATUSES)}")
    if status == "inProgress":
        if user_fraction is None or not (0.0 < user_fraction < 1.0):
            raise ValueError("status='inProgress' requires --user-fraction strictly between 0 and 1")
    elif user_fraction is not None:
        raise ValueError("--user-fraction can only be used with status='inProgress'")

    validate_aab_archive(aab_path)
    if mapping_path is not None and not mapping_path.is_file():
        raise ValueError(f"Mapping file not found: {mapping_path}")

    auth_headers = {"Authorization": f"Bearer {access_token}"}
    pkg = urllib.parse.quote(package_name, safe="")
    edit = http_json("POST", f"{API_BASE}/{pkg}/edits", headers=auth_headers, body={})
    edit_id = edit["id"]
    committed = False
    try:
        try:
            track_state = http_json(
                "GET",
                f"{API_BASE}/{pkg}/edits/{edit_id}/tracks/{urllib.parse.quote(track, safe='')}",
                headers=auth_headers,
            )
        except RuntimeError as error:
            if "HTTP 404" not in str(error):
                raise
            track_state = {}

        if track_has_version_code(track_state, version_code):
            return {
                "result": "already_published",
                "packageName": package_name,
                "track": track,
                "versionCode": version_code,
                "versionName": version_name,
            }

        bundles_resp = http_json(
            "GET",
            f"{API_BASE}/{pkg}/edits/{edit_id}/bundles",
            headers=auth_headers,
        )
        existing_codes = {int(b["versionCode"]) for b in (bundles_resp.get("bundles") or [])}
        uploaded_bundle = False
        if version_code not in existing_codes:
            bundle_resp = http_json(
                "POST",
                f"{UPLOAD_BASE}/{pkg}/edits/{edit_id}/bundles?uploadType=media",
                headers=auth_headers,
                body=aab_path.read_bytes(),
                content_type="application/octet-stream",
            )
            returned_code = int(bundle_resp["versionCode"])
            if returned_code != version_code:
                raise RuntimeError(
                    f"Uploaded bundle reports versionCode {returned_code}, expected {version_code}"
                )
            uploaded_bundle = True

        uploaded_mapping = False
        if mapping_path is not None:
            http_json(
                "POST",
                f"{UPLOAD_BASE}/{pkg}/edits/{edit_id}/apks/{version_code}"
                "/deobfuscationFiles/proguard?uploadType=media",
                headers=auth_headers,
                body=mapping_path.read_bytes(),
                content_type="application/octet-stream",
            )
            uploaded_mapping = True

        release_entry: dict = {
            "name": f"{version_name} ({version_code})",
            "versionCodes": [str(version_code)],
            "status": status,
        }
        if release_notes:
            release_entry["releaseNotes"] = [{"language": "en-US", "text": release_notes}]
        if user_fraction is not None:
            release_entry["userFraction"] = user_fraction

        http_json(
            "PUT",
            f"{API_BASE}/{pkg}/edits/{edit_id}/tracks/{urllib.parse.quote(track, safe='')}",
            headers=auth_headers,
            body={"track": track, "releases": [release_entry]},
        )

        if validate_only:
            http_json(
                "POST",
                f"{API_BASE}/{pkg}/edits/{edit_id}:validate",
                headers=auth_headers,
                body={},
            )
            return {
                "result": "validated",
                "packageName": package_name,
                "track": track,
                "status": status,
                "versionCode": version_code,
                "versionName": version_name,
                "uploadedBundle": uploaded_bundle,
                "uploadedMapping": uploaded_mapping,
            }

        commit_url = f"{API_BASE}/{pkg}/edits/{edit_id}:commit"
        if changes_not_sent_for_review:
            commit_url += "?changesNotSentForReview=true"
        http_json("POST", commit_url, headers=auth_headers, body={})
        committed = True
        return {
            "result": "committed",
            "packageName": package_name,
            "track": track,
            "status": status,
            "versionCode": version_code,
            "versionName": version_name,
            "uploadedBundle": uploaded_bundle,
            "uploadedMapping": uploaded_mapping,
        }
    finally:
        if not committed:
            try:
                http_json("DELETE", f"{API_BASE}/{pkg}/edits/{edit_id}", headers=auth_headers)
            except Exception:
                pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aab", required=True, type=Path, help="Signed Android App Bundle (.aab)")
    parser.add_argument("--mapping", type=Path, help="Optional R8/ProGuard mapping.txt")
    parser.add_argument("--gradle", type=Path, help="Path to app/build.gradle.kts to read package/version")
    parser.add_argument("--package-name", help="Android applicationId (overrides --gradle)")
    parser.add_argument("--version-code", type=int, help="Android versionCode (overrides --gradle)")
    parser.add_argument("--version-name", help="Android versionName (overrides --gradle)")
    parser.add_argument("--track", default="production", help="Google Play track (default: production)")
    parser.add_argument("--status", default="completed", choices=VALID_STATUSES, help="Release status")
    parser.add_argument("--user-fraction", type=float, help="Rollout fraction (0..1) when --status=inProgress")
    parser.add_argument("--notes-file", type=Path, help="Release notes markdown file (trimmed to 500 chars)")
    parser.add_argument("--service-account-file", type=Path, help="Google service account JSON key file")
    parser.add_argument("--workload-identity-provider", help="GCP Workload Identity Provider resource name")
    parser.add_argument("--service-account-email", help="GCP service account email for OIDC impersonation")
    parser.add_argument("--validate-only", action="store_true", help="Validate edit on Play without committing")
    parser.add_argument(
        "--changes-not-sent-for-review",
        action="store_true",
        help="Commit edit without sending for review (for apps with Managed Publishing / error fallback)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    package_name = args.package_name
    version_code = args.version_code
    version_name = args.version_name
    if args.gradle:
        g_pkg, g_code, g_name = read_gradle_version(args.gradle)
        package_name = package_name or g_pkg
        version_code = version_code if version_code is not None else g_code
        version_name = version_name or g_name
    if not package_name or version_code is None or not version_name:
        raise ValueError("Provide --gradle or all of --package-name, --version-code, and --version-name")

    notes_raw = args.notes_file.read_text(encoding="utf-8") if args.notes_file and args.notes_file.is_file() else ""
    notes = format_release_notes(notes_raw, version_name)

    if args.service_account_file:
        sa = json.loads(args.service_account_file.read_text(encoding="utf-8"))
        token = token_from_service_account(sa)
    elif args.workload_identity_provider and args.service_account_email:
        token = token_from_github_oidc(args.workload_identity_provider, args.service_account_email)
    else:
        raise ValueError(
            "Provide either --service-account-file or both --workload-identity-provider and --service-account-email"
        )

    outcome = publish_bundle(
        access_token=token,
        package_name=package_name,
        aab_path=args.aab,
        version_code=version_code,
        version_name=version_name,
        track=args.track,
        status=args.status,
        release_notes=notes,
        mapping_path=args.mapping,
        user_fraction=args.user_fraction,
        validate_only=args.validate_only,
        changes_not_sent_for_review=args.changes_not_sent_for_review,
    )
    print(json.dumps(outcome, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, RuntimeError, subprocess.CalledProcessError) as exc:
        sys.exit(f"publish_google_play: {exc}")
