#!/usr/bin/env python3
"""Set the release version everywhere one tag ships it, then check the result.

Usage: Scripts/bump-version.py 0.10.11 55

Writes the marketing version and build number to LokalBot/Info.plist and
project.yml, and the marketing version to the Linux and Windows workspace
(LinuxWindows/Cargo.toml and its workspace crates in Cargo.lock). Nothing is
staged, committed or tagged.
"""
import argparse
import importlib.util
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("preflight", ROOT / "Scripts/release-preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


def replace(path, pattern, value, flags=re.MULTILINE):
    text = path.read_text()
    updated, count = re.subn(pattern, lambda m: m[1] + value + m[2], text, flags=flags)
    if count != 1:
        raise ValueError(f"{path.relative_to(ROOT)}: expected one match for {pattern}, found {count}")
    path.write_text(updated)


def bump(root, version, build):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Marketing version must have the form 0.8.0")
    if not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("Build number must be a positive integer")
    plist = root / "LokalBot/Info.plist"
    replace(plist, r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)", version)
    replace(plist, r"(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)", build)
    project = root / "project.yml"
    replace(project, r'^(\s+CFBundleShortVersionString:\s*")[^"]*(")', version)
    replace(project, r'^(\s+CFBundleVersion:\s*")[^"]*(")', build)
    replace(root / preflight.PORT_MANIFEST,
            r'(^\[workspace\.package\]\n(?:(?!\[).*\n)*?version\s*=\s*")[^"]*(")', version)
    lock = root / preflight.PORT_LOCKFILE
    blocks = lock.read_text().split("[[package]]")
    for index, block in enumerate(blocks[1:], start=1):
        if "\nsource = " not in block:
            blocks[index] = re.sub(r'^(version = ")[^"]*(")', lambda m: m[1] + version + m[2],
                                   block, count=1, flags=re.MULTILINE)
    lock.write_text("[[package]]".join(blocks))
    return preflight.validate(root, version=version, metadata_only=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version")
    parser.add_argument("build")
    args = parser.parse_args()
    version, build, _ = bump(ROOT, args.version, args.build)
    print(f"Set {version} ({build}) in Info.plist, project.yml, LinuxWindows/Cargo.toml and Cargo.lock")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit(str(error))
