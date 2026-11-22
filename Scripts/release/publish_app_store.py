#!/usr/bin/env python3
"""Upload a signed iPhone and iPad app (.ipa) to App Store Connect and send it to App Review.

Uses only the Python standard library, `openssl` for the ES256 token and Xcode's
`altool` for the upload. Authenticates with an App Store Connect API key (.p8).

Release modes:

- `review`: upload, attach the build to the App Store version, submit it for review,
  and release it automatically once approved.
- `manual`: the same, but the approved version waits for Release in App Store Connect.
- `testflight`: upload only; the processed build is available in TestFlight.

Idempotent: a build number App Store Connect already holds is not uploaded again, and
a version that is already waiting for review, in review or released is left alone.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

API_BASE = "https://api.appstoreconnect.apple.com/v1"
TOKEN_AUDIENCE = "appstoreconnect-v1"
TOKEN_LIFETIME = 900
TOKEN_REFRESH_AFTER = 600
WHATS_NEW_LIMIT = 4000
WHATS_NEW_FALLBACK = "Bug fixes and improvements."
PHONE_TAG = re.compile(r"\s*\(([^()]*\b(?:iPhone|iPad|iOS)\b[^()]*)\)")
OTHER_STORE = re.compile(r"\b(?:Android|Google Play)\b", re.IGNORECASE)
RELEASE_MODES = ("review", "manual", "testflight")
RELEASE_TYPES = {"review": "AFTER_APPROVAL", "manual": "MANUAL"}
EDITABLE_STATES = (
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
    "READY_FOR_REVIEW",
)
SUBMITTED_STATES = (
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "ACCEPTED",
    "PENDING_APPLE_RELEASE",
    "PENDING_DEVELOPER_RELEASE",
    "PROCESSING_FOR_DISTRIBUTION",
    "READY_FOR_DISTRIBUTION",
    "REPLACED_WITH_NEW_VERSION",
)
RETRY_STATUSES = (429, 500, 502, 503, 504)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def format_whats_new(markdown: str, *, limit: int = WHATS_NEW_LIMIT) -> str:
    """Keep the release-note bullets tagged for iPhone or iPad, as plain text.

    The notes cover every platform, and App Review rejects text that names another
    mobile platform, so untagged bullets and ones naming Android are left out.
    """
    text = re.sub(r"<!--.*?-->", "", markdown, flags=re.DOTALL)
    lines: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith("- ") or not PHONE_TAG.search(line):
            continue
        line = PHONE_TAG.sub("", line[2:].strip())
        line = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line)
        line = re.sub(r"\*\*([^*]+)\*\*", r"\1", line)
        line = line.replace("`", "")
        if OTHER_STORE.search(line):
            continue
        lines.append("• " + line)
    combined = "\n".join(lines).strip() or WHATS_NEW_FALLBACK
    if len(combined) <= limit:
        return combined
    trimmed = combined[: limit - 1]
    newline = trimmed.rfind("\n")
    if newline > 0:
        return trimmed[:newline].rstrip() + "…"
    return trimmed.rstrip() + "…"


def read_ipa_version(ipa_path: Path) -> tuple[str, str, str]:
    """Read (bundle identifier, marketing version, build number) from the app inside an .ipa."""
    if not ipa_path.is_file():
        raise ValueError(f"App not found: {ipa_path}")
    with zipfile.ZipFile(ipa_path, "r") as archive:
        names = archive.namelist()
        plists = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(plists) != 1:
            raise ValueError(f"{ipa_path} is not an iOS app archive (expected one Payload/<name>.app/Info.plist)")
        app = plists[0].rsplit("/", 1)[0]
        if f"{app}/_CodeSignature/CodeResources" not in names:
            raise ValueError(f"{ipa_path} is not signed (no _CodeSignature in {app})")
        info = plistlib.loads(archive.read(plists[0]))
    try:
        return info["CFBundleIdentifier"], info["CFBundleShortVersionString"], info["CFBundleVersion"]
    except KeyError as error:
        raise ValueError(f"{ipa_path} has no {error.args[0]} in its Info.plist") from error


def der_to_raw_signature(der: bytes, size: int = 32) -> bytes:
    """Convert openssl's DER ECDSA signature to the fixed-width r||s form JWTs carry."""

    def read_length(offset: int) -> tuple[int, int]:
        length = der[offset]
        if length < 0x80:
            return length, offset + 1
        count = length & 0x7F
        return int.from_bytes(der[offset + 1 : offset + 1 + count], "big"), offset + 1 + count

    def read_integer(offset: int) -> tuple[int, int]:
        if der[offset] != 0x02:
            raise ValueError("Malformed ECDSA signature")
        length, offset = read_length(offset + 1)
        return int.from_bytes(der[offset : offset + length], "big"), offset + length

    try:
        if der[0] != 0x30:
            raise ValueError("Malformed ECDSA signature")
        _, offset = read_length(1)
        r, offset = read_integer(offset)
        s, _ = read_integer(offset)
        return r.to_bytes(size, "big") + s.to_bytes(size, "big")
    except (IndexError, OverflowError) as error:
        raise ValueError("Malformed ECDSA signature") from error


def make_token(key_id: str, issuer_id: str, key_file: Path, *, now: int | None = None) -> str:
    issued = int(time.time()) if now is None else now
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode("utf-8"))
    claims = b64url(
        json.dumps(
            {"iss": issuer_id, "iat": issued, "exp": issued + TOKEN_LIFETIME, "aud": TOKEN_AUDIENCE},
            separators=(",", ":"),
        ).encode("utf-8")
    )
    signing_input = f"{header}.{claims}".encode("ascii")
    der = subprocess.check_output(["openssl", "dgst", "-sha256", "-sign", str(key_file)], input=signing_input)
    return f"{header}.{claims}.{b64url(der_to_raw_signature(der))}"


def http_json(method: str, url: str, *, token: str, body: dict | None = None, timeout: int = 120) -> dict:
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
                return json.loads(raw.decode("utf-8")) if raw else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if method == "GET" and error.code in RETRY_STATUSES and attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            raise RuntimeError(f"HTTP {error.code} from {method} {url}: {detail}") from error
    raise RuntimeError(f"No response from {method} {url}")


class Connect:
    """App Store Connect API client that renews its 15-minute token while a release waits."""

    def __init__(self, key_id: str, issuer_id: str, key_file: Path):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.key_file = key_file
        self.token = ""
        self.issued = 0.0

    def call(self, method: str, path: str, *, query: dict[str, str] | None = None, body: dict | None = None) -> dict:
        if not self.token or time.time() - self.issued > TOKEN_REFRESH_AFTER:
            self.token = make_token(self.key_id, self.issuer_id, self.key_file)
            self.issued = time.time()
        url = f"{API_BASE}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        return http_json(method, url, token=self.token, body=body)


def state_of(version: dict) -> str:
    attributes = version.get("attributes") or {}
    return attributes.get("appVersionState") or attributes.get("appStoreState") or ""


def find_app(api: Connect, bundle_id: str) -> str:
    apps = api.call("GET", "/apps", query={"filter[bundleId]": bundle_id, "limit": "10"}).get("data") or []
    matches = [app["id"] for app in apps if (app.get("attributes") or {}).get("bundleId") == bundle_id]
    if len(matches) != 1:
        raise RuntimeError(f"App Store Connect has no app with bundle identifier {bundle_id} that this key can see")
    return matches[0]


def find_build(api: Connect, app_id: str, version: str, build: str) -> dict | None:
    builds = api.call(
        "GET",
        "/builds",
        query={
            "filter[app]": app_id,
            "filter[version]": build,
            "filter[preReleaseVersion.version]": version,
            "filter[preReleaseVersion.platform]": "IOS",
            "limit": "1",
        },
    ).get("data") or []
    return builds[0] if builds else None


def run_altool(action: str, ipa_path: Path, key_id: str, issuer_id: str, key_file: Path) -> None:
    if key_file.name != f"AuthKey_{key_id}.p8":
        raise ValueError(f"The key file must be named AuthKey_{key_id}.p8 so altool can find it")
    subprocess.run(
        ["xcrun", "altool", action, "-f", str(ipa_path), "-t", "ios", "--apiKey", key_id, "--apiIssuer", issuer_id],
        check=True,
        env=dict(os.environ, API_PRIVATE_KEYS_DIR=str(key_file.parent)),
    )


def wait_for_build(
    api: Connect, app_id: str, version: str, build: str, *, timeout: int = 2700, interval: int = 30
) -> dict:
    deadline = time.monotonic() + timeout
    while True:
        found = find_build(api, app_id, version, build)
        state = (found.get("attributes") or {}).get("processingState") if found else None
        if state == "VALID":
            return found
        if state in ("FAILED", "INVALID"):
            raise RuntimeError(f"App Store Connect could not process build {version} ({build}): {state}")
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"Build {version} ({build}) was still {state or 'missing'} after {timeout // 60} minutes; "
                "rerun this job once App Store Connect lists it"
            )
        time.sleep(interval)


def prepare_version(api: Connect, app_id: str, version: str, release_type: str) -> tuple[dict | None, str]:
    """Find, reuse or create the editable App Store version. Returns (version, outcome)."""
    same = api.call(
        "GET",
        f"/apps/{app_id}/appStoreVersions",
        query={"filter[versionString]": version, "filter[platform]": "IOS", "limit": "5"},
    ).get("data") or []
    if same:
        if state_of(same[0]) in SUBMITTED_STATES:
            return same[0], "already_submitted"
        if state_of(same[0]) not in EDITABLE_STATES:
            raise RuntimeError(f"App Store version {version} is {state_of(same[0])}, which this job cannot change")
        updated = api.call(
            "PATCH",
            f"/appStoreVersions/{same[0]['id']}",
            body={"data": {"type": "appStoreVersions", "id": same[0]["id"], "attributes": {"releaseType": release_type}}},
        )
        return updated.get("data") or same[0], "reused"

    open_versions = api.call(
        "GET",
        f"/apps/{app_id}/appStoreVersions",
        query={"filter[appVersionState]": ",".join(EDITABLE_STATES), "filter[platform]": "IOS", "limit": "5"},
    ).get("data") or []
    if open_versions:
        stale = open_versions[0]
        updated = api.call(
            "PATCH",
            f"/appStoreVersions/{stale['id']}",
            body={
                "data": {
                    "type": "appStoreVersions",
                    "id": stale["id"],
                    "attributes": {"versionString": version, "releaseType": release_type},
                }
            },
        )
        return updated.get("data") or stale, "renamed"

    created = api.call(
        "POST",
        "/appStoreVersions",
        body={
            "data": {
                "type": "appStoreVersions",
                "attributes": {"platform": "IOS", "versionString": version, "releaseType": release_type},
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )
    return created["data"], "created"


def set_whats_new(api: Connect, version_id: str, whats_new: str) -> int:
    localizations = api.call(
        "GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations", query={"limit": "200"}
    ).get("data") or []
    for localization in localizations:
        api.call(
            "PATCH",
            f"/appStoreVersionLocalizations/{localization['id']}",
            body={
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": localization["id"],
                    "attributes": {"whatsNew": whats_new},
                }
            },
        )
    return len(localizations)


def submit_for_review(api: Connect, app_id: str, version: dict) -> str:
    drafts = api.call(
        "GET",
        "/reviewSubmissions",
        query={"filter[app]": app_id, "filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW", "limit": "1"},
    ).get("data") or []
    if drafts:
        submission_id = drafts[0]["id"]
    else:
        submission_id = api.call(
            "POST",
            "/reviewSubmissions",
            body={
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": "IOS"},
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )["data"]["id"]
    if not (drafts and state_of(version) == "READY_FOR_REVIEW"):
        api.call(
            "POST",
            "/reviewSubmissionItems",
            body={
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}},
                    },
                }
            },
        )
    api.call(
        "PATCH",
        f"/reviewSubmissions/{submission_id}",
        body={"data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"submitted": True}}},
    )
    return submission_id


def publish(
    *,
    api: Connect,
    ipa_path: Path,
    release: str,
    whats_new: str,
    expected_version: str | None = None,
    validate_only: bool = False,
    processing_timeout: int = 2700,
    altool=run_altool,
) -> dict:
    if release not in RELEASE_MODES:
        raise ValueError(f"Unsupported release mode {release!r}; expected one of {', '.join(RELEASE_MODES)}")
    bundle_id, version, build = read_ipa_version(ipa_path)
    if expected_version and version != expected_version:
        raise ValueError(f"The app is version {version}, but the release is {expected_version}")
    app_id = find_app(api, bundle_id)
    outcome = {"bundleId": bundle_id, "version": version, "build": build, "release": release}

    if validate_only:
        altool("--validate-app", ipa_path, api.key_id, api.issuer_id, api.key_file)
        return {"result": "validated", **outcome}

    existing = find_build(api, app_id, version, build)
    if existing is None:
        altool("--upload-app", ipa_path, api.key_id, api.issuer_id, api.key_file)
    outcome["uploaded"] = existing is None
    processed = wait_for_build(api, app_id, version, build, timeout=processing_timeout)
    if release == "testflight":
        return {"result": "uploaded", **outcome}

    if (processed.get("attributes") or {}).get("usesNonExemptEncryption") is None:
        raise RuntimeError(
            f"Build {version} ({build}) has no export compliance answer. Answer it for this build in App Store "
            "Connect and rerun, or set ITSAppUsesNonExemptEncryption in Companion/ios/project.yml "
            "(Docs/releasing/ios.md)."
        )

    store_version, how = prepare_version(api, app_id, version, RELEASE_TYPES[release])
    if how == "already_submitted":
        return {"result": "already_submitted", "state": state_of(store_version), **outcome}
    api.call(
        "PATCH",
        f"/appStoreVersions/{store_version['id']}/relationships/build",
        body={"data": {"type": "builds", "id": processed["id"]}},
    )
    set_whats_new(api, store_version["id"], whats_new)
    submit_for_review(api, app_id, store_version)
    return {"result": "submitted", "appStoreVersion": how, **outcome}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ipa", required=True, type=Path, help="Signed app exported for App Store Connect")
    parser.add_argument("--key-file", required=True, type=Path, help="App Store Connect API key, named AuthKey_<id>.p8")
    parser.add_argument("--key-id", required=True, help="App Store Connect API key ID")
    parser.add_argument("--issuer-id", required=True, help="App Store Connect issuer ID")
    parser.add_argument("--release", default="review", choices=RELEASE_MODES, help="How far the release goes")
    parser.add_argument("--version", help="Fail unless the app carries this marketing version")
    parser.add_argument("--notes-file", type=Path, help="Release notes markdown; iPhone and iPad bullets become What's New")
    parser.add_argument("--validate-only", action="store_true", help="Check the app with App Store Connect; upload nothing")
    parser.add_argument("--processing-timeout", type=int, default=2700, help="Seconds to wait for build processing")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.key_file.is_file():
        raise ValueError(f"API key not found: {args.key_file}")
    notes = args.notes_file.read_text(encoding="utf-8") if args.notes_file and args.notes_file.is_file() else ""
    outcome = publish(
        api=Connect(args.key_id, args.issuer_id, args.key_file),
        ipa_path=args.ipa,
        release=args.release,
        whats_new=format_whats_new(notes),
        expected_version=args.version,
        validate_only=args.validate_only,
        processing_timeout=args.processing_timeout,
    )
    print(json.dumps(outcome, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, RuntimeError, subprocess.CalledProcessError) as exc:
        sys.exit(f"publish_app_store: {exc}")
