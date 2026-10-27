#!/usr/bin/env python3
"""Render a Sparkle 2 appcast entry for a notarized LokalBot DMG.

LokalBot's release flow is small and predictable, so this script renders one
`appcast.xml` from a checked-in template rather than depending on Sparkle's
`generate_appcast` helper (which expects a directory of archives and a private
hosting layout):

1. a notarized + stapled DMG is uploaded to a GitHub Release as
   `LokalBot-<version>-macos-arm64.dmg` (pass that name as --archive-filename)
2. Sparkle's `sign_update` tool produces the EdDSA enclosure signature + length
3. this script reads the marketing/build version from the .app and renders the
   feed from Scripts/appcast.template.xml

The signature MUST be computed on the final shipped bytes, so always run this
AFTER notarization/stapling and never modify the DMG afterward.

Usage:
    python3 Scripts/generate_appcast.py \
        --archive build/LokalBot.dmg \
        --archive-filename LokalBot-1.0.0-macos-arm64.dmg \
        --app build/export/LokalBot.app \
        --repo OWNER/REPO \
        --ed-key-file ~/secure/LokalBot-sparkle-key.txt
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import plistlib
import re
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path

# OWNER/REPO is a placeholder: the repo has no git remote yet. Set it (or pass
# --repo, e.g. --repo "$GITHUB_REPOSITORY" in CI) before the first release.
DEFAULT_REPO = "OWNER/REPO"
# Matches sign_update's stdout when signing a non-feed archive:
#   sparkle:edSignature="<base64>" length="<bytes>"
SIGNATURE_PATTERN = re.compile(r'sparkle:edSignature="([^"]+)"\s+length="([^"]+)"')
# Deployment target floor; Sparkle refuses to offer the update below this.
DEFAULT_MINIMUM_SYSTEM_VERSION = "15.0"


def repo_root() -> Path:
    """Repo root, derived from this script's location under Scripts/."""

    return Path(__file__).resolve().parent.parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate LokalBot's Sparkle appcast XML.")
    parser.add_argument(
        "--archive",
        required=True,
        help="Path to the notarized, stapled LokalBot.dmg to sign and enclose.",
    )
    parser.add_argument(
        "--app",
        default=None,
        help=(
            "Path to LokalBot.app, read for CFBundleShortVersionString / "
            "CFBundleVersion / LSMinimumSystemVersion. Optional when "
            "--short-version and --build-version are both supplied."
        ),
    )
    parser.add_argument(
        "--short-version",
        default=None,
        help="Marketing version (CFBundleShortVersionString) override, e.g. 1.0.0.",
    )
    parser.add_argument(
        "--build-version",
        default=None,
        help="Build number (CFBundleVersion) override, e.g. 100.",
    )
    parser.add_argument(
        "--minimum-system-version",
        default=None,
        help=(
            "sparkle:minimumSystemVersion override. Defaults to the app's "
            f"LSMinimumSystemVersion or {DEFAULT_MINIMUM_SYSTEM_VERSION}."
        ),
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output path for the rendered appcast. Defaults to build/appcast.xml.",
    )
    parser.add_argument(
        "--template",
        default=None,
        help="Path to the appcast template. Defaults to Scripts/appcast.template.xml.",
    )
    parser.add_argument(
        "--sign-update-tool",
        default=None,
        help="Explicit path to Sparkle's sign_update tool.",
    )
    parser.add_argument(
        "--ed-key-file",
        default=None,
        help=(
            "Path to the file containing the Sparkle Ed25519 private key (base64). "
            "Optional on a dev Mac where the key lives in the Keychain; required in CI."
        ),
    )
    parser.add_argument(
        "--repo",
        default=DEFAULT_REPO,
        help='GitHub "owner/repo" slug used to build the release + enclosure URLs.',
    )
    parser.add_argument(
        "--release-tag",
        default=None,
        help=(
            "Git tag of the GitHub Release the DMG is uploaded to, e.g. "
            "v1.0.0-beta. Defaults to v<short-version>, which is only correct "
            "for stable tags — pre-release tags carry a suffix the app's "
            "CFBundleShortVersionString doesn't, so the download URL would "
            "point at a release that doesn't exist."
        ),
    )
    parser.add_argument(
        "--archive-filename",
        default=None,
        help="Filename in the GitHub Release download URL. Defaults to the basename of --archive.",
    )
    return parser.parse_args()


def escape_xml(value: str) -> str:
    """Escape the five XML-significant characters for safe attribute/text use."""

    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def read_app_metadata(app_path: Path) -> dict:
    """Read the app's Info.plist (handles both XML and binary plist formats)."""

    info_path = app_path / "Contents" / "Info.plist"
    if not info_path.is_file():
        raise SystemExit(f"Info.plist not found in app bundle: {info_path}")
    with info_path.open("rb") as handle:
        return plistlib.load(handle)


def resolve_versions(args: argparse.Namespace) -> tuple[str, str, str]:
    """Resolve (short_version, build_version, minimum_system_version).

    Explicit flags win; otherwise the values are read from the built app so the
    feed can never advertise a version that disagrees with the shipped binary.
    """

    info: dict = {}
    if args.app:
        app_path = Path(args.app).expanduser().resolve()
        if not app_path.exists():
            raise SystemExit(f"App bundle does not exist: {app_path}")
        info = read_app_metadata(app_path)

    short_version = args.short_version or info.get("CFBundleShortVersionString")
    build_version = args.build_version or info.get("CFBundleVersion")
    minimum_system = (
        args.minimum_system_version
        or info.get("LSMinimumSystemVersion")
        or DEFAULT_MINIMUM_SYSTEM_VERSION
    )

    if not short_version or not build_version:
        raise SystemExit(
            "Could not determine the version. Pass --app /path/to/LokalBot.app, "
            "or both --short-version and --build-version."
        )
    return str(short_version), str(build_version), str(minimum_system)


def candidate_sign_update_paths(explicit_path: str | None) -> list[Path]:
    """Ordered candidate locations for Sparkle's sign_update tool."""

    candidates: list[Path] = []

    if explicit_path:
        candidates.append(Path(explicit_path).expanduser())

    sparkle_bin = os.environ.get("SPARKLE_BIN")
    if sparkle_bin:
        bin_path = Path(sparkle_bin).expanduser()
        # Accept either the tool itself or the directory that contains it.
        candidates.append(bin_path if bin_path.name == "sign_update" else bin_path / "sign_update")

    on_path = shutil.which("sign_update")
    if on_path:
        candidates.append(Path(on_path))

    try:
        xcrun = subprocess.run(
            ["xcrun", "--find", "sign_update"],
            check=False,
            capture_output=True,
            text=True,
        )
        if xcrun.returncode == 0 and xcrun.stdout.strip():
            candidates.append(Path(xcrun.stdout.strip()))
    except FileNotFoundError:
        pass

    # SwiftPM resolves Sparkle's binary artifacts into DerivedData (xcodebuild)
    # or the local .build tree (swift build).
    derived = Path.home() / "Library/Developer/Xcode/DerivedData"
    if derived.exists():
        candidates.extend(derived.glob("*/SourcePackages/artifacts/**/Sparkle/bin/sign_update"))
    candidates.extend((repo_root() / ".build").glob("artifacts/**/Sparkle/bin/sign_update"))

    return candidates


def resolve_sign_update_tool(explicit_path: str | None) -> Path:
    """Return the first usable sign_update tool or fail with guidance."""

    for candidate in candidate_sign_update_paths(explicit_path):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()

    raise SystemExit(
        "Could not locate Sparkle's sign_update tool. Pass --sign-update-tool "
        "/path/to/sign_update, set SPARKLE_BIN to the Sparkle bin/ directory, or "
        "resolve the Sparkle package via an Xcode build first."
    )


def sign_archive(
    sign_update_tool: Path, archive: Path, ed_key_file: Path | None
) -> tuple[str, str]:
    """Sign the archive with sign_update, returning (ed_signature, length)."""

    command = [str(sign_update_tool)]
    if ed_key_file is not None:
        command.extend(["--ed-key-file", str(ed_key_file)])
    command.append(str(archive))

    process = subprocess.run(command, check=True, capture_output=True, text=True)
    match = SIGNATURE_PATTERN.search(process.stdout.strip())
    if match is None:
        raise SystemExit(
            "sign_update returned output in an unexpected format:\n"
            f"{process.stdout.strip()}"
        )
    return match.group(1), match.group(2)


def render_appcast(template_path: Path, replacements: dict[str, str]) -> str:
    """Substitute every {{TOKEN}} in the template with an XML-escaped value."""

    rendered = template_path.read_text(encoding="utf-8")
    for token, value in replacements.items():
        rendered = rendered.replace(token, escape_xml(value))
    return rendered


def main() -> int:
    args = parse_args()

    archive = Path(args.archive).expanduser().resolve()
    if not archive.is_file():
        raise SystemExit(f"Archive does not exist: {archive}")

    template_path = (
        Path(args.template).expanduser().resolve()
        if args.template
        else repo_root() / "Scripts" / "appcast.template.xml"
    )
    if not template_path.is_file():
        raise SystemExit(f"Template does not exist: {template_path}")

    short_version, build_version, minimum_system = resolve_versions(args)

    ed_key_file = None
    if args.ed_key_file:
        ed_key_file = Path(args.ed_key_file).expanduser().resolve()
        if not ed_key_file.is_file():
            raise SystemExit(f"Sparkle Ed25519 private key file does not exist: {ed_key_file}")

    sign_update_tool = resolve_sign_update_tool(args.sign_update_tool)
    ed_signature, archive_length = sign_archive(sign_update_tool, archive, ed_key_file)

    repository_url = f"https://github.com/{args.repo}"
    release_tag = args.release_tag or f"v{short_version}"
    release_page_url = f"{repository_url}/releases/tag/{release_tag}"
    archive_filename = args.archive_filename or archive.name
    # Enclosure points at the version-specific asset (not /latest/) so Sparkle
    # downloads exactly the build it advertised.
    archive_url = (
        f"{repository_url}/releases/download/{release_tag}/"
        f"{urllib.parse.quote(archive_filename)}"
    )
    pub_date = dt.datetime.now(dt.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S %z")

    rendered = render_appcast(
        template_path,
        {
            "{{REPOSITORY_URL}}": repository_url,
            "{{RELEASE_PAGE_URL}}": release_page_url,
            "{{ARCHIVE_URL}}": archive_url,
            "{{SHORT_VERSION}}": short_version,
            "{{BUILD_VERSION}}": build_version,
            "{{MINIMUM_SYSTEM_VERSION}}": minimum_system,
            "{{ARCHIVE_LENGTH}}": archive_length,
            "{{ED_SIGNATURE}}": ed_signature,
            "{{PUB_DATE}}": pub_date,
        },
    )

    output_path = (
        Path(args.output).expanduser().resolve()
        if args.output
        else repo_root() / "build" / "appcast.xml"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered, encoding="utf-8")

    if args.repo == DEFAULT_REPO:
        print(
            "WARNING: --repo is still the OWNER/REPO placeholder; the enclosure "
            "and feed URLs will not resolve until the real slug is set.",
            file=sys.stderr,
        )
    print(f"Generated appcast: {output_path}")
    print(f"Version: {short_version} ({build_version}), min macOS {minimum_system}")
    print(f"Archive URL: {archive_url}")
    print(f"Used sign_update tool: {sign_update_tool}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
