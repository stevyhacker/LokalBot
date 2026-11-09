#!/usr/bin/env python3
"""Compare the models we pin from GitHub releases with what those releases serve.

The pins exist so a replaced asset can't silently change an installed model, which
also means a replaced asset stops the download for everyone. Nothing reported that
when upstream replaced Kokoro, so this runs nightly. A failure needs a person: review
what changed in the asset before moving the pin.

    check-model-pins.py [--report drift.md]
"""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[2]
KOKORO = "LokalBot/Engines/KokoroSpeechEngine.swift"
ONNX = "LokalBot/Engines/OnnxTranscriptionEngine.swift"
RUST = "LinuxWindows/crates/lokalbot-speech/src/models.rs"
RELEASE_URL = re.compile(r"https://github\.com/([\w.-]+/[\w.-]+)/releases/download/([^/\"]+)/([^\"]+)")


class Pin(NamedTuple):
    source: str
    url: str
    size: int
    sha256: str

    @property
    def release(self):
        repository, tag, _ = RELEASE_URL.fullmatch(self.url).groups()
        return repository, tag

    @property
    def asset(self):
        return self.url.rsplit("/", 1)[1]


def number(text):
    return int(text.replace("_", ""))


def swift_cases(source, name):
    """The `case .x: value` lines of one computed property."""
    body = re.search(rf"var {name}: \w+ \{{(.*?)\n        \}}", source, re.S)[1]
    return dict(re.findall(r'case \.(\w+): "?([^"\n]+)"?', body))


def kokoro_pins(source):
    return [Pin(
        KOKORO,
        re.search(r'archiveURL = URL\(\s*string: "([^"]+)"', source)[1],
        number(re.search(r"archiveBytes: Int64 = ([\d_]+)", source)[1]),
        re.search(r'archiveSHA256 = "([0-9a-f]{64})"', source)[1],
    )]


def onnx_pins(source):
    template = re.search(r'URL\(string: "([^"]+)\\\(folderName\)([^"]+)"\)', source)
    folders = swift_cases(source, "folderName")
    sizes = swift_cases(source, "archiveBytes")
    digests = swift_cases(source, "archiveSHA256")
    return [
        Pin(ONNX, f"{template[1]}{folder}{template[2]}", number(sizes[case]), digests[case])
        for case, folder in folders.items()
    ]


def rust_pins(source):
    constants = dict(re.findall(r'const (\w+): &str =\s*"([0-9a-f]{64})"', source))
    pins = []
    for url, digest, size in re.findall(
        r'url: "([^"]+)",\s*sha256: ("[0-9a-f]{64}"|\w+),\s*size: ([\d_]+)', source
    ):
        if RELEASE_URL.fullmatch(url):
            pins.append(Pin(RUST, url, number(size), constants.get(digest, digest.strip('"'))))
    return pins


def all_pins(root=ROOT):
    return (
        kokoro_pins((root / KOKORO).read_text())
        + onnx_pins((root / ONNX).read_text())
        + rust_pins((root / RUST).read_text())
    )


def disagreements(pins):
    """Both apps pin some models. Their pins for one URL have to match."""
    by_url = defaultdict(set)
    for pin in pins:
        by_url[pin.url].add((pin.size, pin.sha256))
    return [
        f"`{url.rsplit('/', 1)[1]}`: {' and '.join(sorted(pin.source for pin in pins if pin.url == url))} pin different files."
        for url, values in sorted(by_url.items())
        if len(values) > 1
    ]


def compare(pin, asset):
    """What's wrong with one pin, given its release asset, or None."""
    where = f"`{pin.asset}` ({pin.source})"
    if asset is None:
        return f"{where}: upstream no longer has this asset."
    problems = []
    if asset["size"] != pin.size:
        problems.append(f"{pin.size} bytes pinned, {asset['size']} served")
    digest = (asset.get("digest") or "").removeprefix("sha256:")
    if digest and digest != pin.sha256:
        problems.append(f"SHA-256 {pin.sha256} pinned, {digest} served")
    if not problems:
        return None
    return f"{where}: {'; '.join(problems)}. Updated {asset.get('updated_at', 'at an unknown time')}."


def fetch_assets(repository, tag):
    """Every asset in a release. A release's own `assets` list can be cut short."""
    run = lambda path, *flags: subprocess.run(
        ["gh", "api", *flags, path], check=True, capture_output=True, text=True
    ).stdout
    release = json.loads(run(f"repos/{repository}/releases/tags/{tag}"))
    pages = run(f"repos/{repository}/releases/{release['id']}/assets?per_page=100", "--paginate", "--slurp")
    return {asset["name"]: asset for page in json.loads(pages) for asset in page}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()

    pins = all_pins()
    problems = disagreements(pins)
    releases = {}
    for pin in pins:
        if pin.release not in releases:
            releases[pin.release] = fetch_assets(*pin.release)
        problems.append(compare(pin, releases[pin.release].get(pin.asset)))
    problems = [problem for problem in problems if problem]

    if not problems:
        unverified = [pin.asset for pin in pins if not releases[pin.release][pin.asset].get("digest")]
        print(f"All {len(pins)} pins match upstream.")
        if unverified:
            print(f"Upstream publishes no digest for these, so only their size was compared: {', '.join(unverified)}")
        return 0
    report = "\n".join(
        ["A pinned model no longer matches its release. Its download fails until the pin moves.",
         "Review what changed in the asset before updating the pin.", ""]
        + [f"- {problem}" for problem in problems]
    )
    print(report, file=sys.stderr)
    if args.report:
        args.report.write_text(report + "\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
