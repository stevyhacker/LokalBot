#!/usr/bin/env python3
"""Exercise extracted native archives without installing or using private data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--archive", type=Path)
parser.add_argument("--revision", default=os.environ.get("LOKALBOT_BUILD_REVISION"))
parser.add_argument("--ui", action="store_true", help="Run native UI checks on remote/hosted Linux")
args = parser.parse_args()
if args.ui and not sys.platform.startswith("linux"):
    parser.error("UI checks require a remote or hosted Linux desktop")
archives = [args.archive] if args.archive else list((ROOT / "dist").glob("*.tar.gz")) + list((ROOT / "dist").glob("*.zip"))
if len(archives) != 1:
    parser.error("Choose one native archive with --archive")
archive = archives[0].resolve()
checksum = archive.with_name(archive.name + ".sha256").read_text().split()[0]
if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
    raise SystemExit("Archive checksum mismatch")
checks = ["archive checksum"]
with tempfile.TemporaryDirectory(prefix="lokalbot-package-") as temporary:
    destination = Path(temporary)
    if archive.name.endswith(".zip"):
        with zipfile.ZipFile(archive) as source:
            source.extractall(destination)
    else:
        with tarfile.open(archive) as source:
            source.extractall(destination, filter="data")
    packages = list(destination.glob("lokalbot-desktop-*"))
    assert len(packages) == 1, "Archive must contain one application directory"
    package = packages[0]
    metadata = json.loads((package / "build.json").read_text())
    if args.revision and metadata["revision"] != args.revision:
        raise SystemExit("Archive was built from a different source revision")
    suffix = ".exe" if sys.platform == "win32" else ""
    cli = package / ("lokalbot-desktop-cli" + suffix)
    app = package / ("lokalbot-desktop" + suffix)
    whisper = package / ("whisper-cli" + suffix)
    assert app.is_file(), "Native UI binary is missing"
    env = {k: v for k, v in os.environ.items() if k not in ("OPENROUTER_API_KEY", "LOKALBOT_STORAGE_ROOT")}
    library = destination / "synthetic-library"

    def run(*command):
        return subprocess.run(command, cwd=package, env=env, capture_output=True, text=True, check=True, timeout=30).stdout

    def owner(*arguments):
        return json.loads(run(str(cli), "--root", str(library), *arguments))

    run(str(cli), "--help")
    run(str(whisper), "--help")
    health = owner("health")
    assert health["meetings"] == health["moments"] == 0
    assert not health["jobs"] and not health["generations"] and not health["local_whisper_configured"]
    checks.extend(["packaged CLI and CPU Whisper launch", "empty library default"])
    owner("seed")
    owner("configure", "--meeting-access", "true")
    meetings = owner("list")
    assert len(meetings) == 3
    assert owner("search", "microphone"), "Packaged FTS search failed"
    identifier = meetings[0]["id"]
    owner("note", identifier, "Fictional packaged note survives process restart")
    assert owner("get", identifier)["notes"] == "Fictional packaged note survives process restart"
    checks.append("packaged persistence and search")
    if args.ui:
        env["LOKALBOT_DESKTOP_BINARY"] = str(app)
        env["LOKALBOT_DESKTOP_CLI"] = str(cli)
        subprocess.run([sys.executable, str(ROOT / "scripts/ui-smoke.py")], cwd=ROOT, env=env, check=True, timeout=240)
        subprocess.run(["dbus-run-session", "--", sys.executable, str(ROOT / "scripts/capture-smoke.py")], cwd=ROOT, env=env, check=True, timeout=60)
        checks.append("packaged native UI and guarded capture")
    print(json.dumps({"passed": checks, "revision": metadata["revision"], "synthetic_only": True}, indent=2))
