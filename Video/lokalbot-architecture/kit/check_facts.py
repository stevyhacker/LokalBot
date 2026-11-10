#!/usr/bin/env python3
"""Fail when a scene shows a number that FACTS.md does not have.

    python3 kit/check_facts.py [film folder ...]      (default: all three)

Reads the text of every compositions/*.html (markup and script strings, not the styles or the
generated cue block), finds each number that carries a unit, and checks it against
kit/facts.json. Clock times such as 10:26 and file sizes of the five models are the usual finds.
"""
import json
import re
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parent
FILMS = ["one-sentence", "inside-the-mac", "taking-turns"]
UNIT = (r"(?:GB|GiB|MB|ms|tok/s|languages|dimensions|-dimensional|-d\b|% ?(?:DER|WER)|× ?real time|"
        r"-minute|min\b|s\b)")
NUMBER = re.compile(r"(?<![\w.#-])(\d+(?:\.\d+)?)[  ]?(" + UNIT + r")")


def visible(text):
    text = re.sub(r"<style>.*?</style>", " ", text, flags=re.S)
    text = re.sub(r"/\* cues:begin \*/.*?/\* cues:end \*/", " ", text, flags=re.S)
    text = re.sub(r"<!--.*?-->", " ", text, flags=re.S)
    script = "\n".join(re.findall(r"<script>(.*?)</script>", text, flags=re.S))
    markup = re.sub(r"<script>.*?</script>", " ", text, flags=re.S)
    markup = re.sub(r"<[^>]+>", " ", markup)
    strings = " ".join(m.group(2) for m in re.finditer(r"([\"'`])((?:\\.|(?!\1).)*)\1", script))
    return markup + " " + strings


def main():
    allowed = {re.sub(r"\s+", " ", item) for item in json.loads((KIT / "facts.json").read_text())["allowed"]}
    films = [Path(arg) for arg in sys.argv[1:]] or [KIT.parent / film for film in FILMS]
    bad = 0
    for film in films:
        for path in sorted(film.glob("compositions/*.html")):
            for match in NUMBER.finditer(visible(path.read_text())):
                found = re.sub(r"\s+", " ", match.group(0).replace(" ", " "))
                spaced = f"{match.group(1)} {match.group(2).strip()}"
                joined = f"{match.group(1)}{match.group(2).strip()}"
                if not {found, spaced, joined} & allowed:
                    bad += 1
                    print(f"{film.name}/{path.name}: \"{found}\" is not in kit/facts.json")
    if bad:
        sys.exit(f"{bad} number(s) to trace to FACTS.md or remove")
    print("every number with a unit is in kit/facts.json")


if __name__ == "__main__":
    main()
