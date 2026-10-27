#!/usr/bin/env python3
"""Settings each release had when a user approved a remote model server and
kept scheduled digests and dreams on. Written into the old app's defaults
before it opens the fixture library. Also picks the versions an Upgrade
fixtures run builds."""
import hashlib
import json
from pathlib import Path
import re
import sys

FIXTURES = Path(__file__).resolve().parents[2] / "LokalBotTests/Fixtures/upgrade"


def _tuple(version):
    return tuple(int(part) for part in version.split("."))


def committed_versions():
    """Releases with a committed fixture, oldest first. The folders are the
    only list of fixture versions."""
    return sorted((path.name for path in FIXTURES.iterdir() if (path / "manifest.json").is_file()), key=_tuple)


def plan(event, requested):
    """Versions an Upgrade fixtures run builds, for its matrix: the requested
    ones (a release tag or a dispatch), otherwise every committed fixture. A
    pull request only checks the generator on the newest release, since the
    release run builds each new fixture."""
    versions = [version.removeprefix("v") for version in requested]
    for version in versions:
        if not re.fullmatch(r"\d+\.\d+\.\d+", version):
            raise ValueError(f"Not a stable release version: {version}")
    if versions:
        return versions
    committed = committed_versions()
    return committed[-1:] if event == "pull_request" else committed


def profile(version):
    value = {
        "summarizerBackend": "OpenAI-compatible server",
        "openAIBaseURL": "https://openrouter.ai/api/v1",
        "openAIModel": "z-ai/glm-5.3-flash",
        "approvedRemoteInferenceOrigins": ["https://openrouter.ai"],
        "dayDigestAutoEnabled": True,
        "dayDigestHour": 18,
        "dreamingEnabled": True,
        "dreamingHour": 4,
        "trackingEnabled": True,
    }
    # Only 0.9.0 and 0.9.1 had a separate approval for scheduled remote runs;
    # 0.9.2 removed it (#113).
    if (0, 9, 0) <= _tuple(version) < (0, 9, 2):
        value["approvedRemoteAutomationOrigins"] = ["https://openrouter.ai"]
    return json.dumps(value, sort_keys=True)


def fixture_key_hex(account):
    return hashlib.sha256(f"lokalbot-upgrade-fixture-{account}".encode()).hexdigest()


if __name__ == "__main__":
    if sys.argv[1] == "key":
        print(fixture_key_hex(sys.argv[2]))
    elif sys.argv[1] == "plan":
        print(f"versions={json.dumps(plan(sys.argv[2], sys.argv[3:]))}")
    else:
        print(profile(sys.argv[1]))
