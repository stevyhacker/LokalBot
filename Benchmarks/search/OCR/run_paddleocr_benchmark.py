#!/usr/bin/env python3
import argparse
import csv
import json
import os
import re
import statistics
import time
from pathlib import Path

from paddleocr import PaddleOCR


VARIANTS = {
    "ppocr-v5-mobile": ("PP-OCRv5_mobile_det", "PP-OCRv5_mobile_rec"),
    "ppocr-v5-server": ("PP-OCRv5_server_det", "PP-OCRv5_server_rec"),
    "ppocr-v6-medium": ("PP-OCRv6_medium_det", "PP-OCRv6_medium_rec"),
}


def tokens(text: str) -> set[str]:
    return set(re.findall(r"[A-Za-z0-9_./:-]{3,}", text.lower()))


def jaccard(a: str, b: str) -> float:
    left = tokens(a)
    right = tokens(b)
    if not left and not right:
        return 1.0
    if not left or not right:
        return 0.0
    return len(left & right) / len(left | right)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vision-tsv", required=True)
    parser.add_argument("--variant", choices=sorted(VARIANTS), required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--limit", type=int, default=5)
    return parser.parse_args()


def load_rows(path: Path, limit: int):
    rows = []
    with path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            rows.append(row)
            if len(rows) >= limit:
                break
    return rows


def main():
    args = parse_args()
    os.makedirs(args.output_dir, exist_ok=True)

    det_name, rec_name = VARIANTS[args.variant]
    load_start = time.perf_counter()
    ocr = PaddleOCR(
        text_detection_model_name=det_name,
        text_recognition_model_name=rec_name,
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
    )
    load_ms = (time.perf_counter() - load_start) * 1000

    print(
        "variant\tid\tapp\tload_ms\tinfer_ms\tchars\tlines\tmean_score\tvision_chars\tchar_ratio\ttoken_jaccard\toutput_path",
        flush=True,
    )
    metrics = []
    for row in load_rows(Path(args.vision_tsv), args.limit):
        image_path = row["png_path"]
        vision_text = Path(row["vision_text_path"]).read_text(encoding="utf-8", errors="ignore")
        infer_start = time.perf_counter()
        result = ocr.predict(image_path)[0].json["res"]
        infer_ms = (time.perf_counter() - infer_start) * 1000
        texts = result.get("rec_texts") or []
        scores = result.get("rec_scores") or []
        text = "\n".join(texts)
        mean_score = statistics.mean(scores) if scores else 0.0
        output_path = Path(args.output_dir) / f"shot-{row['id']}.{args.variant}.txt"
        output_path.write_text(text, encoding="utf-8")
        json_path = Path(args.output_dir) / f"shot-{row['id']}.{args.variant}.json"
        json_path.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
        ratio = len(text) / len(vision_text) if vision_text else 0.0
        overlap = jaccard(vision_text, text)
        metrics.append(
            {
                "infer_ms": infer_ms,
                "chars": len(text),
                "lines": len(texts),
                "mean_score": mean_score,
                "token_jaccard": overlap,
            }
        )
        print(
            f"{args.variant}\t{row['id']}\t{row['app']}\t{load_ms:.1f}\t{infer_ms:.1f}\t"
            f"{len(text)}\t{len(texts)}\t{mean_score:.3f}\t{len(vision_text)}\t{ratio:.2f}\t"
            f"{overlap:.3f}\t{output_path}",
            flush=True,
        )

    if metrics:
        print(
            "SUMMARY\t"
            f"{args.variant}\t"
            f"n={len(metrics)}\t"
            f"mean_infer_ms={statistics.mean(m['infer_ms'] for m in metrics):.1f}\t"
            f"min_infer_ms={min(m['infer_ms'] for m in metrics):.1f}\t"
            f"max_infer_ms={max(m['infer_ms'] for m in metrics):.1f}\t"
            f"mean_chars={statistics.mean(m['chars'] for m in metrics):.1f}\t"
            f"mean_lines={statistics.mean(m['lines'] for m in metrics):.1f}\t"
            f"mean_score={statistics.mean(m['mean_score'] for m in metrics):.3f}\t"
            f"mean_token_jaccard={statistics.mean(m['token_jaccard'] for m in metrics):.3f}",
            flush=True,
        )


if __name__ == "__main__":
    main()
