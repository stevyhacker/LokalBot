#!/usr/bin/env python3
"""Decide whether a pull request needs the Build workflow's macOS jobs.

Build's checks are required, so the workflow always runs and reports them. A
pull request that changes only documentation, the website and the scripts that
generate it, marketing assets, video or distribution notes skips the compile and
tests; GitHub reports a job skipped by its condition as passing. Everything else
builds, including the files the app bundles (PRIVACY.md, LICENSE, LICENSES/,
THIRD_PARTY_NOTICES.md and the CLI skill) and Benchmarks/, which unit tests read.
Pushes, schedules, dispatches and calls always build, but a push of only these
paths doesn't start Build or XcodeGen at all: their `paths-ignore` lists mirror
DOCS_ONLY.

Nothing here reaches a release artifact, so release-candidate.py also lets these
paths change on master after a release candidate. Add a path only if no build,
test, packaging or publishing step reads it.
"""
import importlib.util
import os
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('ui_relevance', Path(__file__).with_name('ui-relevance.py'))
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)

DOCS_ONLY = [
    "Docs/**", "Website/**", "Video/**", "Assets/**", "Distribution/**",
    "wrangler.jsonc", ".github/ISSUE_TEMPLATE/**", ".github/PULL_REQUEST_TEMPLATE.md",
    "README.md", "AGENTS.md", "CLAUDE.md", "CONTEXT.md", "DEVELOPMENT.md", "RELEASING.md",
    "SECURITY.md", "SUPPORT.md",
]


def docs_only(path):
    return any(ui.matches(path, pattern) for pattern in DOCS_ONLY)


def relevant(paths):
    # An empty or unreadable diff builds.
    return not paths or not all(docs_only(path) for path in paths)


def main(argv):
    if os.environ.get("GITHUB_EVENT_NAME") != "pull_request":
        ui.write_output(True)
        return 0
    ui.write_output(relevant(ui.changed_paths(argv[1], argv[2])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
