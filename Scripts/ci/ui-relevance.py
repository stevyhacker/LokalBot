#!/usr/bin/env python3
"""Decide whether a pull request needs the UI suite, and flag oversized PRs.

Every pull request runs ui-tests.yml so its aggregate `XCUITest (macOS)` check
always reports. Changes that cannot affect the app or its UI tests skip the
expensive jobs and pass the aggregate gate. So do draft pull requests: the
suite runs when one is marked ready for review (`ready_for_review`), and that
run's pending check blocks merging until it passes. Drafts cannot be merged.
"""
import fnmatch
import os
import subprocess
import sys

UI_PATTERNS = [
    "LokalBot/**", "LokalBotUITests/**", "project.yml", "Scripts/test/ui-tests.sh",
    # Dependency bumps change compiled code without touching LokalBot/.
    "LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "Scripts/ci/**", "Scripts/build/fetch-llama.sh", "Scripts/build/fetch-sherpa.sh",
    ".github/workflows/ui-tests.yml",
]
SIZE_WARNING_FILES = 60


def matches(path, pattern):
    if pattern.endswith("/**"):
        return path.startswith(pattern[:-2])
    return fnmatch.fnmatchcase(path, pattern)


def relevant(paths):
    return any(matches(path, pattern) for path in paths for pattern in UI_PATTERNS)


def size_warning(paths):
    if len(paths) <= SIZE_WARNING_FILES:
        return None
    return (f"::warning::This PR touches {len(paths)} files (over {SIZE_WARNING_FILES}). "
            "Consider splitting it into smaller pull requests.")


def changed_paths(base, head):
    output = subprocess.check_output(["git", "diff", "--name-only", f"{base}...{head}"], text=True)
    return [line for line in output.splitlines() if line]


def write_output(value):
    line = f"relevant={'true' if value else 'false'}\n"
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as stream:
            stream.write(line)
    print(line, end="")


def main(argv):
    if os.environ.get("GITHUB_EVENT_NAME") != "pull_request":
        write_output(True)
        return 0
    if os.environ.get("PULL_REQUEST_DRAFT") == "true":
        print("Draft pull request: the UI suite runs when it is marked ready for review.")
        write_output(False)
        return 0
    paths = changed_paths(argv[1], argv[2])
    warning = size_warning(paths)
    if warning:
        print(warning)
    write_output(relevant(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
