#!/usr/bin/env python3
import argparse
import csv
import json
import os
import statistics
import time
from pathlib import Path

from paddleocr import PaddleOCR


VARIANTS = {
    "ppocr-v5-mobile": ("PP-OCRv5_mobile_det", "PP-OCRv5_mobile_rec"),
    "ppocr-v5-server": ("PP-OCRv5_server_det", "PP-OCRv5_server_rec"),
    "ppocr-v6-medium": ("PP-OCRv6_medium_det", "PP-OCRv6_medium_rec"),
}


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--variant", choices=sorted(VARIANTS), default="ppocr-v6-medium")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--limit", type=int, default=0)
    return parser.parse_args()


def load_rows(path: Path, limit: int):
    rows = []
    with path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            rows.append(row)
            if limit and len(rows) >= limit:
                break
    return rows


def main():
    args = parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

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

    print("engine\tid\tapp\tload_ms\tinfer_ms\tchars\tlines\tmean_score\toutput_path\ttruth_path\tpng_path", flush=True)
    timings = []
    for row in load_rows(Path(args.manifest), args.limit):
        infer_start = time.perf_counter()
        result = ocr.predict(row["png_path"])[0].json["res"]
        infer_ms = (time.perf_counter() - infer_start) * 1000
        texts = result.get("rec_texts") or []
        scores = result.get("rec_scores") or []
        text = "\n".join(texts)
        mean_score = statistics.mean(scores) if scores else 0.0

        output_path = output_dir / f"{row['id']}.{args.variant}.txt"
        output_path.write_text(text, encoding="utf-8")
        json_path = output_dir / f"{row['id']}.{args.variant}.json"
        json_path.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
        timings.append(infer_ms)

        print(
            f"{args.variant}\t{row['id']}\t{row['app']}\t{load_ms:.1f}\t{infer_ms:.1f}\t"
            f"{len(text)}\t{len(texts)}\t{mean_score:.3f}\t{output_path}\t{row['truth_path']}\t{row['png_path']}",
            flush=True,
        )

    if timings:
        print(
            f"SUMMARY\t{args.variant}\tn={len(timings)}\tmean_infer_ms={statistics.mean(timings):.1f}\t"
            f"min_infer_ms={min(timings):.1f}\tmax_infer_ms={max(timings):.1f}",
            flush=True,
        )


if __name__ == "__main__":
    main()
