#!/usr/bin/env python3
"""Check that every crate compiled into lokalbot-sync on Apple and Android has its notice.

LICENSES/rust-crates.md is generated for the Linux and Windows targets only
(LinuxWindows/about.toml). The Mac app and the phone apps compile lokalbot-sync
for other targets, where a dependency can pull in a crate that file never
lists. Such a crate has to be named, with its version, in the companion
section of THIRD_PARTY_NOTICES.md.

    python3 Scripts/ci/check-sync-crate-notices.py

Needs cargo. It resolves the dependency tree from LinuxWindows/Cargo.lock and
compiles nothing.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# The targets Scripts/build/build-sync-xcframework.sh and Scripts/build/build-sync-android.sh build.
TARGETS = ["aarch64-apple-darwin", "aarch64-apple-ios", "aarch64-apple-ios-sim",
           "aarch64-linux-android", "x86_64-linux-android"]


def listed(generated_notice):
    """(name, version) of every crate LICENSES/rust-crates.md names."""
    return set(re.findall(r"^- ([A-Za-z0-9_.-]+) ([0-9][^ ]*)", generated_notice, flags=re.MULTILINE))


def tree_crates(tree_output):
    """(name, version) of every third-party crate in `cargo tree --format {p}` output."""
    crates = set()
    for line in tree_output.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[0].startswith("lokalbot-"):
            continue
        crates.add((parts[0], parts[1].removeprefix("v")))
    return crates


def unnamed(crates, generated_notice, notices):
    """Crates that neither the generated file nor THIRD_PARTY_NOTICES.md names with their version."""
    known = listed(generated_notice)
    return sorted(crate for crate in crates
                  if crate not in known and f"{crate[0]} {crate[1]}" not in notices)


def main():
    generated = (ROOT / "LICENSES/rust-crates.md").read_text(encoding="utf-8")
    notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    failed = False
    for target in TARGETS:
        tree = subprocess.run(
            ["cargo", "tree", "--locked", "-p", "lokalbot-sync", "--target", target,
             "-e", "normal,build", "--prefix", "none", "--format", "{p}"],
            cwd=ROOT / "LinuxWindows", check=True, capture_output=True, text=True).stdout
        crates = tree_crates(tree)
        missing = unnamed(crates, generated, notices)
        print(f"{target}: {len(crates)} crates, {len(missing)} without a notice")
        for name, version in missing:
            failed = True
            print(f"  {name} {version}: add it to the companion section of THIRD_PARTY_NOTICES.md")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
