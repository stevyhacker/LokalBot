"""Download and verify the pinned public checkpoint; never read private app data."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil

from huggingface_hub import hf_hub_download

ROOT = Path(__file__).resolve().parent


def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


if __name__ == "__main__":
    spec = json.loads((ROOT / "model.json").read_text())
    destination = ROOT / "model"
    destination.mkdir(exist_ok=True)
    assert shutil.disk_usage(destination).free > 80 * 1024**3, "Insufficient free space for checkpoint and headroom"
    auxiliary = ["config.json", "configuration_memt.py", "modeling_memt.py", "generation_config.json",
                 "chat_template.jinja", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json",
                 "merges.txt", "vocab.json"]
    expected = {entry["file"]: entry for entry in spec["weights"]}

    def fetch(name):
        path = hf_hub_download(spec["repo"], name, revision=spec["revision"], local_dir=destination)
        digest = sha(path)
        if name in expected:
            assert Path(path).stat().st_size == expected[name]["bytes"], name
            assert digest == expected[name]["sha256"], name
        if name in spec["source_files"]:
            assert digest == spec["source_files"][name], name
        print("verified", name, flush=True)
        return name, digest

    # The host's system SSD becomes unresponsive under concurrent Xet writes/hash reads.
    # Sequential downloads keep this preparation job from starving runtime imports.
    with ThreadPoolExecutor(max_workers=1) as pool:
        verified = dict(pool.map(fetch, auxiliary + list(expected)))
    (ROOT / "verified-model-files.json").write_text(json.dumps(verified, indent=2) + "\n")
    print("DOWNLOAD_VERIFIED", flush=True)
