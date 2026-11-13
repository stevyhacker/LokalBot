#!/usr/bin/env python3
import argparse
import csv
import re
import statistics
import sys
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path


TOKEN_RE = re.compile(r"[a-z0-9_./:-]+")


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower()).strip()


def token_counter(text: str) -> Counter:
    return Counter(TOKEN_RE.findall(normalize(text)))


def token_metrics(truth: str, prediction: str):
    truth_tokens = token_counter(truth)
    pred_tokens = token_counter(prediction)
    overlap = sum((truth_tokens & pred_tokens).values())
    truth_total = sum(truth_tokens.values())
    pred_total = sum(pred_tokens.values())
    precision = overlap / pred_total if pred_total else 0.0
    recall = overlap / truth_total if truth_total else 0.0
    f1 = (2 * precision * recall / (precision + recall)) if precision + recall else 0.0
    union = truth_total + pred_total - overlap
    jaccard = overlap / union if union else 1.0
    return precision, recall, f1, jaccard


def char_similarity(truth: str, prediction: str):
    return SequenceMatcher(None, normalize(truth), normalize(prediction), autojunk=False).ratio()


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("tsv", nargs="+")
    return parser.parse_args()


def iter_rows(paths):
    for path in paths:
        with Path(path).open("r", encoding="utf-8") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            for row in reader:
                if not row.get("truth_path") or not row.get("output_path"):
                    continue
                yield row


def main():
    args = parse_args()
    by_engine = defaultdict(list)
    print(
        "engine\tid\tapp\tinfer_ms\tchars\ttruth_chars\ttoken_precision\ttoken_recall\t"
        "token_f1\ttoken_jaccard\tchar_similarity\toutput_path"
    )

    for row in iter_rows(args.tsv):
        truth = Path(row["truth_path"]).read_text(encoding="utf-8", errors="ignore")
        output = Path(row["output_path"]).read_text(encoding="utf-8", errors="ignore")
        precision, recall, f1, jaccard = token_metrics(truth, output)
        similarity = char_similarity(truth, output)
        infer_ms = float(row.get("infer_ms") or 0)
        chars = int(row.get("chars") or len(output))
        record = {
            "infer_ms": infer_ms,
            "chars": chars,
            "truth_chars": len(truth),
            "token_precision": precision,
            "token_recall": recall,
            "token_f1": f1,
            "token_jaccard": jaccard,
            "char_similarity": similarity,
        }
        by_engine[row["engine"]].append(record)
        print(
            f"{row['engine']}\t{row['id']}\t{row['app']}\t{infer_ms:.1f}\t{chars}\t{len(truth)}\t"
            f"{precision:.3f}\t{recall:.3f}\t{f1:.3f}\t{jaccard:.3f}\t{similarity:.3f}\t{row['output_path']}"
        )

    for engine, records in by_engine.items():
        print(
            f"SUMMARY\t{engine}\tn={len(records)}\t"
            f"mean_infer_ms={statistics.mean(r['infer_ms'] for r in records):.1f}\t"
            f"mean_chars={statistics.mean(r['chars'] for r in records):.1f}\t"
            f"mean_token_precision={statistics.mean(r['token_precision'] for r in records):.3f}\t"
            f"mean_token_recall={statistics.mean(r['token_recall'] for r in records):.3f}\t"
            f"mean_token_f1={statistics.mean(r['token_f1'] for r in records):.3f}\t"
            f"mean_token_jaccard={statistics.mean(r['token_jaccard'] for r in records):.3f}\t"
            f"mean_char_similarity={statistics.mean(r['char_similarity'] for r in records):.3f}"
        )


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
