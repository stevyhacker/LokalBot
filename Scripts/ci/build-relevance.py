#!/usr/bin/env python3
"""Decide whether a pull request needs the Build workflow's macOS jobs.

Build's checks are required, so the workflow always runs and reports them. A
pull request that changes only documentation, the website, marketing assets,
video or distribution notes skips the compile and tests; GitHub reports a job
skipped by its condition as passing. Everything else builds, including the
files the app bundles (PRIVACY.md, LICENSE, LICENSES/, THIRD_PARTY_NOTICES.md
and the CLI skill) and Benchmarks/, which unit tests read. Pushes, schedules,
dispatches and calls always build.
"""
import importlib.util
import os
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('ui_relevance', Path(__file__).with_name('ui-relevance.py'))
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)

DOCS_ONLY = [
    "Docs/**", "web/**", "Video/**", "Assets/**", "Distribution/**", "cloudflare/**",
    "wrangler.jsonc", "vercel.json", ".github/ISSUE_TEMPLATE/**", ".github/PULL_REQUEST_TEMPLATE.md",
    "README.md", "AGENTS.md", "CLAUDE.md", "CONTEXT.md", "DEVELOPMENT.md", "RELEASING.md",
    "SECURITY.md", "SUPPORT.md", "CLOUDFLARE.md",
]


def relevant(paths):
    # An empty or unreadable diff builds.
    return not paths or any(not any(ui.matches(path, pattern) for pattern in DOCS_ONLY) for path in paths)


def main(argv):
    if os.environ.get("GITHUB_EVENT_NAME") != "pull_request":
        ui.write_output(True)
        return 0
    ui.write_output(relevant(ui.changed_paths(argv[1], argv[2])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
