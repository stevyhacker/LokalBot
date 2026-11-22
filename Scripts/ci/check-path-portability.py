#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path

ILLEGAL = re.compile(r'[<>:"\\|?*\x00-\x1f]')
RESERVED = re.compile(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$", re.IGNORECASE)


def reasons(path):
    found = []
    for part in path.split("/"):
        if ILLEGAL.search(part) and "illegal character" not in found:
            found.append("illegal character")
        if part.endswith((" ", ".")) and "trailing space or dot" not in found:
            found.append("trailing space or dot")
        if RESERVED.match(part) and "reserved device name" not in found:
            found.append("reserved device name")
    return found


def tracked_paths(root):
    listing = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True).stdout
    return [path for path in listing.decode("utf-8").split("\0") if path]


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(".")
    paths = tracked_paths(root)
    failures = [(path, reason) for path in paths for reason in reasons(path)]
    for path, reason in failures:
        print(f"{path}: {reason}", file=sys.stderr)
    if failures:
        print(f"{len({path for path, _ in failures})} tracked path(s) cannot be checked out on Windows", file=sys.stderr)
        return 1
    print(f"all {len(paths)} tracked paths can be checked out on Windows")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
