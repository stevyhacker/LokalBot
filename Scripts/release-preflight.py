#!/usr/bin/env python3
"""Read-only release validation; --metadata-only checks version/build consistency for general CI."""
import argparse
import plistlib
from pathlib import Path
import re
import subprocess
import sys


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


PORT_MANIFEST = "LinuxWindows/Cargo.toml"
PORT_LOCKFILE = "LinuxWindows/Cargo.lock"
PORT_UPDATE_KEY = "LinuxWindows/crates/lokalbot-update/src/lib.rs"


def validate_port_version(root, version):
    """The Linux and Windows app ships from the same tag, so its workspace
    version and every workspace crate in Cargo.lock repeat the marketing version."""
    manifest = (root / PORT_MANIFEST).read_text()
    section = re.search(r'^\[workspace\.package\]\n((?:(?!\[).*\n)*)', manifest, re.MULTILINE)
    declared = section and re.search(r'^version\s*=\s*"([^"]+)"', section[1], re.MULTILINE)
    if not declared or declared[1] != version:
        raise ValueError(f"{PORT_MANIFEST} and Info.plist disagree on the version")
    # Workspace members are the lockfile packages without a registry or git source.
    members = [block for block in (root / PORT_LOCKFILE).read_text().split("[[package]]")[1:]
               if "\nsource = " not in block]
    stale = sorted(re.search(r'name = "([^"]+)"', block)[1] for block in members
                   if re.search(r'^version = "([^"]+)"', block, re.MULTILINE)[1] != version)
    if not members or stale:
        raise ValueError(f"{PORT_LOCKFILE} disagrees with Info.plist for {', '.join(stale) or 'every crate'}; "
                         "run Scripts/bump-version.py or cargo update --workspace")


def validate_port_update_key(root, info):
    """Linux and Windows updates verify against the macOS app's Sparkle key."""
    source = (root / PORT_UPDATE_KEY).read_text()
    embedded = re.search(r'^pub const PUBLIC_KEY: &str = "([^"]+)";', source, re.MULTILINE)
    if not embedded or embedded[1] != info.get("SUPublicEDKey"):
        raise ValueError(f"{PORT_UPDATE_KEY} and Info.plist disagree on SUPublicEDKey")


def validate(root, *, version=None, candidate=False, staged=False, remote="origin", metadata_only=False):
    if metadata_only and (candidate or staged):
        raise ValueError("--metadata-only cannot be combined with --candidate or --staged")
    info = plistlib.loads((root / "LokalBot/Info.plist").read_bytes())
    actual = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", actual):
        raise ValueError("Marketing version must have the form 0.8.0")
    if not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("Build number must be a positive integer")
    if version and actual != version:
        raise ValueError(f"Requested {version}, but Info.plist contains {actual}")
    project = (root / "project.yml").read_text()
    for key, value in [("CFBundleShortVersionString", actual), ("CFBundleVersion", build)]:
        matches = re.findall(rf'^\s+{key}:\s*["\']?([^\s"\'#]+)["\']?\s*(?:#.*)?$', project, re.MULTILINE)
        if matches != [value]:
            raise ValueError(f"project.yml and Info.plist disagree on {key}")
    validate_port_version(root, actual)
    validate_port_update_key(root, info)
    if metadata_only:
        return actual, build, None
    notes_path = f"Scripts/release-notes/v{actual}.md"
    notes = (root / notes_path).read_text()
    if not re.search(r"^- \S", notes, re.MULTILINE):
        raise ValueError("Release notes need a human-readable change summary")
    comparison = re.search(
        r"https://github\.com/stevyhacker/lokalbot/compare/(v\d+\.\d+\.\d+)\.\.\.(v\d+\.\d+\.\d+)", notes)
    if not comparison or comparison[2] != f"v{actual}":
        raise ValueError("Release notes must compare the previous tag to this version")
    base = comparison[1]
    if tuple(map(int, base[1:].split('.'))) >= tuple(map(int, actual.split('.'))):
        raise ValueError("Changelog base must precede the release version")
    if candidate:
        tag = f"v{actual}"
        if git(root, "tag", "--list", tag):
            raise ValueError(f"Tag {tag} already exists locally")
        # Network/auth failures also fail closed; they are not tag absence.
        if git(root, "ls-remote", "--tags", remote, f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"):
            raise ValueError(f"Tag {tag} already exists on {remote}")
        reachable = git(root, "tag", "--merged", "HEAD", "--list", "v*").splitlines()
        stable = [tag for tag in reachable if re.fullmatch(r"v\d+\.\d+\.\d+", tag)]
        if stable and base != max(stable, key=lambda tag: tuple(map(int, tag[1:].split('.')))):
            raise ValueError("Changelog base must be the latest reachable stable tag; fetch tags first")
        git(root, "merge-base", "--is-ancestor", base, "HEAD")
        previous = plistlib.loads(subprocess.check_output(
            ["git", "-C", str(root), "show", f"{base}:LokalBot/Info.plist"]))
        if int(build) <= int(previous["CFBundleVersion"]):
            raise ValueError("Build number must increase from the changelog base")
        fixture = root / "LokalBotTests/Fixtures/upgrade" / base[1:] / "manifest.json"
        if not fixture.exists():
            raise ValueError(f"Add the upgrade fixture for {base} (Scripts/upgrade-fixtures/add.sh {base[1:]}) before releasing")
    if staged:
        required = {"project.yml", "LokalBot/Info.plist", PORT_MANIFEST, PORT_LOCKFILE, notes_path}
        changed = set(git(root, "diff", "--cached", "--name-only").splitlines())
        if changed != required:
            raise ValueError(f"Stage only the release metadata together: {', '.join(sorted(required))}")
        for path in required:
            content = subprocess.check_output(["git", "-C", str(root), "show", f":{path}"])
            if content != (root / path).read_bytes():
                raise ValueError(f"Staged content differs from the validated file: {path}")
    return actual, build, base


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version")
    parser.add_argument("--metadata-only", action="store_true",
                        help="Check version/build consistency without requiring stable-release notes")
    parser.add_argument("--candidate", action="store_true")
    parser.add_argument("--staged", action="store_true")
    parser.add_argument("--remote", default="origin")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    version, build, base = validate(root, version=args.version, candidate=args.candidate,
                                    staged=args.staged, remote=args.remote, metadata_only=args.metadata_only)
    changelog = f", changelog from {base}" if base else ""
    print(f"Release metadata valid: {version} ({build}){changelog}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
