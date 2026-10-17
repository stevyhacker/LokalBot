#!/usr/bin/env python3
"""Package the built native binaries. Does not sign, install, or publish."""
from pathlib import Path
import hashlib
import json
import os
import re
import platform
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
os_name = platform.system().lower()
suffix = ".exe" if os_name == "windows" else ""
name = f"lokalbot-desktop-0.1.0-{os_name}-x86_64"
stage = root / "dist" / name
stage.mkdir(parents=True, exist_ok=True)
for binary in ["lokalbot-desktop", "lokalbot-desktop-cli"]:
    shutil.copy2(root / "target/release" / (binary + suffix), stage)
whisper = list((root / "tools/whisper.cpp/build").glob("bin/**/whisper-cli" + suffix))
if whisper:
    shutil.copy2(whisper[0], stage)
    license_file = root / "tools/whisper.cpp/LICENSE"
    shutil.copy2(license_file, stage / "whisper-LICENSE")
for source in ["README.md", "PRIVACY.md"]:
    shutil.copy2(root / source, stage)
shutil.copy2(root.parent / "LICENSE", stage / "LICENSE")
shutil.copytree(root / "assets/fonts", stage / "font-licenses", dirs_exist_ok=True)
shutil.copytree(root / "packaging", stage / "packaging", dirs_exist_ok=True)
revision = os.environ.get("LOKALBOT_BUILD_REVISION") or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
if not re.fullmatch(r"[0-9a-f]{40}", revision):
    raise SystemExit("Invalid build revision")
(stage / "build.json").write_text(json.dumps({"revision": revision, "os": os_name, "architecture": "x86_64", "rust": "1.95.0", "gpui-kit": "0.7.0"}, indent=2))
archive = shutil.make_archive(str(stage), "zip" if os_name == "windows" else "gztar", root_dir=stage.parent, base_dir=stage.name)
path = Path(archive)
(path.with_name(path.name + ".sha256")).write_text(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n")
shutil.rmtree(stage)
print(path)
