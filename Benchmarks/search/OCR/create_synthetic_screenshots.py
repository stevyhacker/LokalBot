#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


WIDTH = 1440
HEIGHT = 900
FONT_DIR = Path("/System/Library/Fonts/Supplemental")


class Fonts:
    def __init__(self):
        self._cache = {}

    def get(self, name: str, size: int):
        key = (name, size)
        if key not in self._cache:
            path = FONT_DIR / name
            if not path.exists():
                path = FONT_DIR / "Arial.ttf"
            self._cache[key] = ImageFont.truetype(str(path), size=size)
        return self._cache[key]

    def regular(self, size: int):
        return self.get("Arial.ttf", size)

    def bold(self, size: int):
        return self.get("Arial Bold.ttf", size)

    def mono(self, size: int):
        return self.get("Andale Mono.ttf", size)


FONTS = Fonts()


def draw_text(draw, truth, xy, text, font, fill, include=True):
    draw.text(xy, text, font=font, fill=fill)
    if include:
        truth.append(text)


def rect(draw, box, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=7, fill=fill, outline=outline, width=width)


def save_case(output_dir: Path, case_id: str, app: str, image: Image.Image, truth: list[str]):
    image_path = output_dir / f"{case_id}.png"
    truth_path = output_dir / f"{case_id}.truth.txt"
    image.save(image_path)
    truth_path.write_text("\n".join(truth) + "\n", encoding="utf-8")
    return {
        "id": case_id,
        "app": app,
        "png_path": str(image_path.resolve()),
        "truth_path": str(truth_path.resolve()),
    }


def make_editor():
    img = Image.new("RGB", (WIDTH, HEIGHT), "#1f2430")
    draw = ImageDraw.Draw(img)
    truth = []

    draw.rectangle((0, 0, WIDTH, 48), fill="#151922")
    draw.rectangle((0, 48, 235, HEIGHT), fill="#171b24")
    draw.rectangle((235, 48, WIDTH - 320, HEIGHT - 32), fill="#202532")
    draw.rectangle((WIDTH - 320, 48, WIDTH, HEIGHT - 32), fill="#252b38")
    draw.rectangle((0, HEIGHT - 32, WIDTH, HEIGHT), fill="#116b5f")

    draw_text(draw, truth, (22, 15), "LokalBot - ReviewOCR.swift", FONTS.bold(18), "#e7ecf3")
    draw_text(draw, truth, (258, 17), "ReviewOCR.swift", FONTS.regular(15), "#cbd5e1")
    draw_text(draw, truth, (32, 74), "Search files", FONTS.regular(15), "#9aa5b1")
    draw_text(draw, truth, (28, 116), "Sources", FONTS.bold(14), "#d6deeb")
    for i, item in enumerate(["Engines", "OCRBenchmark.swift", "ProcessingPipeline.swift", "Tests", "ScreenshotOCRTests.swift"]):
        draw_text(draw, truth, (42, 150 + i * 32), item, FONTS.regular(15), "#b9c4d0")

    code_lines = [
        "// OCR comparison fixture",
        "let candidate = \"PP-OCRv6 medium\"",
        "let baseline = \"Apple Vision\"",
        "let latencyBudgetMs = 750",
        "",
        "func shouldPromote(candidate: OCRResult) -> Bool {",
        "    return candidate.f1 > 0.92 && candidate.latencyMs < latencyBudgetMs",
        "}",
        "",
        "XCTAssertGreaterThan(candidate.tokenF1, baseline.tokenF1)",
        "XCTAssertLessThan(candidate.meanLatencyMs, 750)",
    ]
    for i, line in enumerate(code_lines, start=1):
        y = 84 + (i - 1) * 32
        draw.text((265, y), f"{i:>2}", font=FONTS.mono(16), fill="#6b7280")
        if line:
            draw_text(draw, truth, (315, y), line, FONTS.mono(16), "#e5e7eb")

    draw_text(draw, truth, (1144, 84), "Review note", FONTS.bold(17), "#f8fafc")
    note_lines = [
        "Keep Vision as default unless the model is",
        "both faster and more accurate.",
        "Failed checks: latency budget exceeded",
        "Decision: do not switch yet",
    ]
    for i, line in enumerate(note_lines):
        draw_text(draw, truth, (1144, 124 + i * 30), line, FONTS.regular(15), "#d5dce8")
    draw_text(draw, truth, (24, 876), "main  2026-06-24  UTF-8  Swift", FONTS.regular(13), "#e0fffb")
    return "synth-01", "CodeEditor", img, truth


def make_dashboard():
    img = Image.new("RGB", (WIDTH, HEIGHT), "#f6f7fb")
    draw = ImageDraw.Draw(img)
    truth = []

    draw.rectangle((0, 0, WIDTH, 70), fill="#ffffff")
    draw.rectangle((0, 70, WIDTH, 118), fill="#172033")
    draw.rounded_rectangle((180, 18, 720, 50), radius=15, fill="#eef2f7")
    draw_text(draw, truth, (202, 25), "localhost:3000/reports/ocr-latency", FONTS.regular(15), "#334155")
    draw_text(draw, truth, (34, 84), "OCR Benchmark Dashboard", FONTS.bold(20), "#f8fafc")
    draw_text(draw, truth, (1180, 86), "Window: Last 7 days", FONTS.regular(15), "#cbd5e1")

    cards = [
        ("Mean latency", "243 ms", "Baseline: Apple Vision"),
        ("Token F1", "0.96", "Candidate target: 0.92"),
        ("Queue depth", "12", "Pending screenshots"),
        ("Errors", "0", "Last run clean"),
    ]
    for i, (label, value, sub) in enumerate(cards):
        x = 34 + i * 346
        rect(draw, (x, 146, x + 310, 258), "#ffffff", "#d9dee8")
        draw_text(draw, truth, (x + 20, 166), label, FONTS.regular(16), "#475569")
        draw_text(draw, truth, (x + 20, 192), value, FONTS.bold(32), "#101827")
        draw_text(draw, truth, (x + 20, 232), sub, FONTS.regular(14), "#64748b")

    rect(draw, (34, 296, 1404, 812), "#ffffff", "#d9dee8")
    draw_text(draw, truth, (64, 325), "Model comparison", FONTS.bold(21), "#111827")
    headers = ["Engine", "Images", "Mean latency", "Token F1", "Decision"]
    xs = [64, 450, 610, 840, 1040]
    for x, h in zip(xs, headers):
        draw_text(draw, truth, (x, 374), h, FONTS.bold(15), "#334155")
    rows = [
        ["Apple Vision", "15", "243 ms", "0.96", "Current default"],
        ["PP-OCRv6 medium", "5", "22.43 s", "0.21", "Too slow"],
        ["PaddleOCR-VL GGUF", "3", "2.74 s", "0.10", "Partial output"],
        ["DeepSeek-OCR GGUF", "3", "1.64 s", "0.00", "Hallucinated"],
    ]
    for r, row in enumerate(rows):
        y = 422 + r * 70
        draw.rectangle((56, y - 14, 1382, y + 38), fill="#f8fafc" if r % 2 == 0 else "#ffffff")
        for x, cell in zip(xs, row):
            draw_text(draw, truth, (x, y), cell, FONTS.regular(16), "#1f2937")
    draw_text(draw, truth, (64, 760), "Recommendation: keep Apple Vision as default OCR pipeline.", FONTS.bold(17), "#0f766e")
    return "synth-02", "BrowserDashboard", img, truth


def make_terminal():
    img = Image.new("RGB", (WIDTH, HEIGHT), "#101317")
    draw = ImageDraw.Draw(img)
    truth = []
    draw.rectangle((0, 0, WIDTH, 42), fill="#2b3037")
    draw_text(draw, truth, (20, 12), "Terminal - ocr-benchmark", FONTS.bold(15), "#e5e7eb")
    lines = [
        "$ ./scripts/run_ocr_benchmark --limit 5 --engine ppocr-v6-medium",
        "Loaded 5 synthetic screenshots from Benchmarks/search/OCR/synthetic/manifest.tsv",
        "synth-01 CodeEditor infer_ms=21877 chars=1342 token_f1=0.812",
        "synth-02 BrowserDashboard infer_ms=19433 chars=1038 token_f1=0.846",
        "synth-03 Terminal infer_ms=17722 chars=1197 token_f1=0.927",
        "synth-04 ChatNotes infer_ms=22491 chars=902 token_f1=0.781",
        "synth-05 Preferences infer_ms=20814 chars=998 token_f1=0.833",
        "SUMMARY engine=ppocr-v6-medium mean_latency_ms=20467 mean_token_f1=0.840",
        "$ curl -s http://127.0.0.1:8097/health",
        "{\"status\":\"ok\"}",
        "$ ./scripts/run_vlm_ocr --engine paddleocr-vl-gguf --max-tokens 1024",
        "synth-01 generated 892 characters in 2850 ms",
        "synth-02 generated 764 characters in 2714 ms",
        "WARN output truncated before footer",
        "$",
    ]
    for i, line in enumerate(lines):
        color = "#84cc16" if line.startswith("$") else "#d1d5db"
        if line.startswith("WARN"):
            color = "#fbbf24"
        draw_text(draw, truth, (28, 70 + i * 42), line, FONTS.mono(18), color)
    return "synth-03", "Terminal", img, truth


def make_chat_notes():
    img = Image.new("RGB", (WIDTH, HEIGHT), "#eef2f7")
    draw = ImageDraw.Draw(img)
    truth = []
    draw.rectangle((0, 0, 310, HEIGHT), fill="#ffffff")
    draw.rectangle((310, 0, WIDTH, 72), fill="#ffffff")
    draw_text(draw, truth, (28, 28), "LokalBot Notes", FONTS.bold(20), "#111827")
    for i, item in enumerate(["OCR benchmark", "Pipeline review", "Release checklist", "Meeting follow-up"]):
        y = 92 + i * 64
        draw.rectangle((16, y - 10, 294, y + 42), fill="#e7f0ff" if i == 0 else "#ffffff")
        draw_text(draw, truth, (34, y), item, FONTS.regular(16), "#1f2937")
    draw_text(draw, truth, (342, 24), "OCR benchmark", FONTS.bold(22), "#111827")
    draw_text(draw, truth, (1170, 28), "Updated 10:42 AM", FONTS.regular(15), "#64748b")

    messages = [
        ("Stevan", "Can we switch away from Vision if the model is better?"),
        ("Codex", "Not yet. PP-OCRv6 found more snippets but was about 90x slower."),
        ("Stevan", "What about PaddleOCR-VL on llama.cpp?"),
        ("Codex", "It ran quickly enough for manual use, but missed too much screenshot text."),
        ("Decision", "Default OCR remains Apple Vision. Keep VLM parsing as an optional experiment."),
    ]
    y = 116
    for speaker, body in messages:
        fill = "#ffffff" if speaker != "Codex" else "#e9f7ef"
        rect(draw, (346, y, 1338, y + 94), fill, "#d6dde8")
        draw_text(draw, truth, (370, y + 16), speaker, FONTS.bold(15), "#0f172a")
        draw_text(draw, truth, (370, y + 46), body, FONTS.regular(18), "#1f2937")
        y += 118

    draw_text(draw, truth, (370, 790), "Action item: test five synthetic screenshots with ground truth labels.", FONTS.bold(17), "#334155")
    return "synth-04", "ChatNotes", img, truth


def make_preferences():
    img = Image.new("RGB", (WIDTH, HEIGHT), "#f8fafc")
    draw = ImageDraw.Draw(img)
    truth = []
    draw.rectangle((0, 0, WIDTH, 76), fill="#ffffff")
    draw_text(draw, truth, (34, 26), "LokalBot Preferences", FONTS.bold(22), "#111827")
    draw_text(draw, truth, (1190, 28), "Profile: Local Mac", FONTS.regular(16), "#475569")

    draw.rectangle((0, 76, 260, HEIGHT), fill="#eff3f8")
    for i, item in enumerate(["General", "Capture", "Transcription", "OCR", "Storage", "Privacy"]):
        y = 118 + i * 58
        if item == "OCR":
            draw.rounded_rectangle((18, y - 12, 238, y + 32), radius=8, fill="#dbeafe")
        draw_text(draw, truth, (42, y), item, FONTS.regular(17), "#1f2937")

    draw_text(draw, truth, (308, 116), "OCR pipeline", FONTS.bold(24), "#111827")
    settings = [
        ("Default engine", "Apple Vision"),
        ("Recognition level", "Accurate"),
        ("Language correction", "Off"),
        ("Screenshot interval", "30 seconds"),
        ("Minimum confidence", "0.55"),
        ("Fallback engine", "None"),
    ]
    for i, (label, value) in enumerate(settings):
        y = 170 + i * 72
        draw_text(draw, truth, (330, y), label, FONTS.regular(17), "#475569")
        rect(draw, (650, y - 14, 1050, y + 32), "#ffffff", "#d1d8e3")
        draw_text(draw, truth, (674, y), value, FONTS.bold(16), "#111827")

    rect(draw, (308, 644, 1336, 814), "#fff7ed", "#fed7aa")
    draw_text(draw, truth, (334, 670), "Reliability guardrail", FONTS.bold(19), "#9a3412")
    guardrail = [
        "Do not promote a new OCR engine unless p95 latency stays below 750 ms.",
        "Quality must improve on real screenshots, not only synthetic fixtures.",
        "Run a battery test before enabling continuous capture on battery power.",
    ]
    for i, line in enumerate(guardrail):
        draw_text(draw, truth, (334, 710 + i * 30), line, FONTS.regular(16), "#7c2d12")
    return "synth-05", "Preferences", img, truth


CASES = [make_editor, make_dashboard, make_terminal, make_chat_notes, make_preferences]


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", default="Benchmarks/search/OCR/synthetic")
    return parser.parse_args()


def main():
    args = parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    for make_case in CASES:
        case_id, app, image, truth = make_case()
        rows.append(save_case(output_dir, case_id, app, image, truth))

    manifest_path = output_dir / "manifest.tsv"
    with manifest_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["id", "app", "png_path", "truth_path"],
            delimiter="\t",
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} screenshots to {output_dir}")
    print(f"Manifest: {manifest_path}")


if __name__ == "__main__":
    main()
