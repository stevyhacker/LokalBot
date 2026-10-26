"""Builds the exact requests PersonalLearning.run sends, from the Swift source.

Usage: python3 -I build_prompts.py PersonalLearning.swift cases.json prompts.json
"""
import json
import re
import sys


def swift_literal(source, anchor):
    """The multi-line string literal that follows `anchor`, as Swift reads it."""
    start = source.index(anchor) + len(anchor)
    open_q = source.index('"""', start)
    body_start = source.index("\n", open_q) + 1
    close_q = source.index('"""', body_start)
    raw = source[body_start:close_q]
    indent = len(raw) - len(raw.rstrip(" "))  # closing delimiter's indentation
    lines = raw.split("\n")[:-1]
    lines = [l[indent:] if l.startswith(" " * indent) else l.lstrip(" ") for l in lines]
    text = "\n".join(lines)
    text = re.sub(r"\\\n", "", text)  # line continuation
    text = text.replace('\\"', '"')
    return text


def main():
    swift, cases_path, out_path = sys.argv[1:4]
    src = open(swift).read()
    system = swift_literal(src, "static let system =")
    block = swift_literal(src, "static func prompt(")
    assert "\\(maxPerNight)" in block
    block = block.replace("\\(maxPerNight)", "3")
    assert "\\(" not in block and "\\(" not in system, "unhandled interpolation"
    cases = json.load(open(cases_path))
    out = []
    for c in cases:
        lines = [block]
        if c["known"]:
            lines.append("")
            lines.append("Already known (do not repeat):")
            for k in c["known"][:40]:
                lines.append(f"- {k}")
        lines.append("")
        lines.append(f"The user's lines from {c['day']}, each with where they said, typed, or dictated it:")
        for l in c["lines"]:
            lines.append(f"{l['handle']} ({l['label'][:80]}): {l['text']}")
        out.append({"id": c["id"], "system": system, "user": "\n".join(lines)})
    json.dump(out, open(out_path, "w"), ensure_ascii=False, indent=1)
    print(system)
    print("----")
    print(out[4]["user"])


if __name__ == "__main__":
    main()
