#!/usr/bin/env python3
"""Stage the fictional library, the model and the settings for the film.

    stage.py model <dir>                    download the default autocomplete model into <dir>, print its path
    stage.py library <new-dir> <model>      seed the launch-pricing library and install <model> in it
    stage.py settings <suite>               write the settings suite the filmed app runs on
    stage.py shot <shot.json> <docs-dir>    write the take's document, print its path

The library is the README GIF's (Scripts/readme-gif/seed_library.py): a team
settled launch pricing on a call, so autocomplete can finish "the Team plan
will be $15" from that meeting. The model is the catalog's default
autocomplete entry (ModelCatalog.qualityCotypingID), checked against its
pinned SHA-256. Settings keep autocomplete on device and everything that could
capture or learn off, as for the README GIF.
"""
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CATALOG = ROOT / "LokalBot/Engines/ModelCatalog.swift"

spec = importlib.util.spec_from_file_location("prepare_filming", ROOT / "Scripts/readme-gif/prepare_filming.py")
prepare_filming = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_filming)

SETTINGS = dict(prepare_filming.SETTINGS)
SETTINGS.update({
    "cotypingAcceptGranularity": "word",
    "menuBarOnly": True,
    # Dictation's shortcut tap sits in the keystroke path on the app's main
    # thread; on a busy hosted runner the rig's keys came out lost and out of
    # order. Reading the visible window walks TextEdit's accessibility tree,
    # which took 9 s there. Neither is part of this demo.
    "dictationEnabled": False,
    "cotypingUseVisibleContext": False,
})


def default_model():
    """fileName, url and sha256 of the default autocomplete entry."""
    source = CATALOG.read_text()
    model_id = re.search(r'static let qualityCotypingID = "([^"]+)"', source).group(1)
    match = re.search(r'Entry\(id: qualityCotypingID,.*?fileName: "([^"]+)",\s*url: "([^"]+)",\s*sha256: "([0-9a-f]{64})"',
                      source, re.S)
    if not match:
        raise SystemExit(f"cannot find {model_id} in {CATALOG}")
    return model_id, *match.groups()


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(8 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def model(directory):
    model_id, name, url, digest = default_model()
    target = Path(directory) / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists() or sha256(target) != digest:
        partial = target.with_suffix(".part")
        print(f"downloading {model_id} from {url}", file=sys.stderr)
        subprocess.run(["curl", "-fL", "--retry", "3", "--retry-delay", "5", "-sS", "-o", str(partial), url], check=True)
        if sha256(partial) != digest:
            raise SystemExit(f"{name} does not match its pinned SHA-256")
        partial.rename(target)
    print(target)


def library(root, model_path):
    root, model_path = Path(root).resolve(), Path(model_path).resolve()
    subprocess.run([sys.executable, str(ROOT / "Scripts/readme-gif/seed_library.py"), str(root)],
                   check=True, stdout=subprocess.DEVNULL)
    _, name, _, digest = default_model()
    models = root / "models"
    models.mkdir(exist_ok=True)
    # A clone where the filesystem offers one, else a hard link: no second copy.
    target = models / name
    if subprocess.run(["cp", "-c", str(model_path), str(target)], capture_output=True).returncode != 0:
        try:
            target.hardlink_to(model_path)
        except OSError:
            shutil.copyfile(model_path, target)
    (models / f"{name}.sha256").write_text(digest)
    control = root / "control"
    control.mkdir(exist_ok=True)
    print(root)


def settings(suite):
    if not suite.startswith("lokalbot.autocomplete-demo."):
        raise SystemExit("the defaults suite must be a throwaway lokalbot.autocomplete-demo.* name")
    blob = json.dumps(SETTINGS, separators=(",", ":")).encode()
    subprocess.run(["defaults", "delete", suite], capture_output=True)
    subprocess.run(["defaults", "write", suite, "lokalbotv3.settings", "-data", blob.hex()], check=True)
    for key in ("lokalbotv3.onboarding.shown", "lokalbotv3.gettingStartedDismissed"):
        subprocess.run(["defaults", "write", suite, key, "-bool", "YES"], check=True)


def shot(path, docs):
    data = json.loads(Path(path).read_text())
    docs = Path(docs)
    docs.mkdir(parents=True, exist_ok=True)
    document = docs / data["file"]
    document.write_text(data.get("opening", ""))
    print(document)


def main():
    commands = {"model": (model, 1), "library": (library, 2), "settings": (settings, 1), "shot": (shot, 2)}
    if len(sys.argv) < 2 or sys.argv[1] not in commands or len(sys.argv) != commands[sys.argv[1]][1] + 2:
        raise SystemExit(__doc__)
    function, _ = commands[sys.argv[1]]
    function(*sys.argv[2:])


if __name__ == "__main__":
    main()
