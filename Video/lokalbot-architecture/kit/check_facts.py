#!/usr/bin/env python3
"""Fail when a scene shows a number that FACTS.md does not have, or when model metadata drifts.

    python3 kit/check_facts.py [film folder ...]      (default: all three)

Reads the text of every compositions/*.html (markup and script strings, not the styles or the
generated cue block), finds each number that carries a unit, and checks it against
kit/facts.json. Also validates pinned v0.14.0 fine-tune entries against ModelCatalog.swift and
QwenLlamaASR.swift when run inside the LokalBot repository.
"""
import json
import re
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parent
REPO = KIT.parents[2]
FILMS = ["one-sentence", "inside-the-mac", "taking-turns"]
UNIT = (r"(?:GB|GiB|MB|ms|tok/s|languages|dimensions|-dimensional|-d\b|% ?(?:DER|WER)|[×x] ?real time|"
        r"-minute|min\b|s\b)")
NUMBER = re.compile(r"(?<![\w.#-])(\d+(?:\.\d+)?)[ \u00a0]?(" + UNIT + r")")


def visible(text):
    text = re.sub(r"<style>.*?</style>", " ", text, flags=re.S)
    text = re.sub(r"/\* cues:begin \*/.*?/\* cues:end \*/", " ", text, flags=re.S)
    text = re.sub(r"<!--.*?-->", " ", text, flags=re.S)
    script = "\n".join(re.findall(r"<script>(.*?)</script>", text, flags=re.S))
    markup = re.sub(r"<script>.*?</script>", " ", text, flags=re.S)
    markup = re.sub(r"<[^>]+>", " ", markup)
    strings = " ".join(m.group(2) for m in re.finditer(r"([\"'`])((?:\\.|(?!\1).)*)\1", script))
    return markup + " " + strings


def check_catalog_sync(facts):
    models = facts.get("models", {})
    if not models:
        return 0
    catalog_path = REPO / "LokalBot/Engines/ModelCatalog.swift"
    asr_path = REPO / "LokalBot/Engines/QwenLlamaASR.swift"
    errors = 0
    if catalog_path.exists():
        catalog = catalog_path.read_text(encoding="utf-8")
        for role, key in (("think", "defaultSummarizationID"), ("autocomplete", "qualityCotypingID")):
            spec = models.get(role)
            if not spec:
                continue
            expected_id = f'static let {key} = "{spec["id"]}"'
            if expected_id not in catalog:
                errors += 1
                print(f"kit/facts.json ({role}): {expected_id} not found in ModelCatalog.swift")
            expected_file = f'fileName: "{spec["fileName"]}"'
            if expected_file not in catalog:
                errors += 1
                print(f"kit/facts.json ({role}): {expected_file} not found in ModelCatalog.swift")
            expected_size = f'sizeGB: {spec["sizeGB"]:.2f}'
            if expected_size not in catalog:
                errors += 1
                print(f"kit/facts.json ({role}): {expected_size} not found in ModelCatalog.swift")
    if asr_path.exists():
        asr = asr_path.read_text(encoding="utf-8")
        spec = models.get("transcribe")
        if spec:
            for field in ("fileName", "projectorFileName"):
                token = f'name: "{spec[field]}"'
                if token not in asr:
                    errors += 1
                    print(f"kit/facts.json (transcribe): {token} not found in QwenLlamaASR.swift")
            sizes = [int(m.replace("_", "")) for m in re.findall(r"bytes:\s*([\d_]+)", asr)]
            expected_bytes = [
                int(m.replace("_", ""))
                for m in re.findall(
                    rf'{re.escape(spec["fileName"])}".*?bytes:\s*([\d_]+)|{re.escape(spec["projectorFileName"])}".*?bytes:\s*([\d_]+)',
                    asr,
                    flags=re.S,
                )
                for m in m
                if m
            ]
            if len(expected_bytes) == 2:
                gb = round(sum(expected_bytes) / 1_000_000_000, 2)
                if gb != round(float(spec["sizeGB"]), 2):
                    errors += 1
                    print(f"kit/facts.json (transcribe): sizeGB {spec['sizeGB']} != {gb} in QwenLlamaASR.swift")
            elif not sizes:
                errors += 1
                print("kit/facts.json (transcribe): could not read byte sizes from QwenLlamaASR.swift")
    return errors


def main():
    facts = json.loads((KIT / "facts.json").read_text(encoding="utf-8"))
    allowed = {re.sub(r"\s+", " ", item) for item in facts["allowed"]}
    films = [Path(arg) for arg in sys.argv[1:]] or [KIT.parent / film for film in FILMS]
    bad = check_catalog_sync(facts)
    for film in films:
        for path in sorted(film.glob("compositions/*.html")):
            if path.name == "captions.html":
                continue
            for match in NUMBER.finditer(visible(path.read_text(encoding="utf-8"))):
                found = re.sub(r"\s+", " ", match.group(0).replace("\u00a0", " "))
                spaced = f"{match.group(1)} {match.group(2).strip()}"
                joined = f"{match.group(1)}{match.group(2).strip()}"
                if not {found, spaced, joined} & allowed:
                    bad += 1
                    print(f"{film.name}/{path.name}: \"{found}\" is not in kit/facts.json")
    if bad:
        sys.exit(f"{bad} fact check failure(s) against FACTS.md / ModelCatalog.swift")
    print("every number with a unit is in kit/facts.json and matches v0.14.0 ModelCatalog.swift")


if __name__ == "__main__":
    main()
