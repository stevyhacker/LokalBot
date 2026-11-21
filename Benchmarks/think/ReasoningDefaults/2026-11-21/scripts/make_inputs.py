import json, os, sys
from pathlib import Path

repo = Path(sys.argv[1])
out = Path(sys.argv[2])
os.environ["SUMMARY_BENCH_DIR"] = str(out / "ami-data")
sys.path.insert(0, str(repo / "Benchmarks/think/SummaryQuality"))
import prepare

def write(name, segments, language):
    folder = out / "inputs" / name
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "transcript.json").write_text(json.dumps({"engine": "reference", "segments": segments}, indent=1))
    print(name, language, len(segments), "segments", sum(len(s["text"].split()) for s in segments), "words")

for lang, name in [("en", "sample-en"), ("sr-Latn", "sample-sr")]:
    ref = json.loads((repo / f"LokalBot/Resources/SampleMeeting/reference.{lang}.json").read_text())
    labels = {}
    segments = []
    for turn in ref["turns"]:
        labels.setdefault(turn["speaker"], f"them {len(labels) + 1}")
        segments.append({"start": turn["start"], "end": turn["end"], "speaker": labels[turn["speaker"]],
                         "text": turn["text"], "timingPrecision": "span",
                         "attribution": {"identity": "other", "method": "diarization", "source": "system"}})
    write(name, segments, lang)

(out / "ami-data").mkdir(parents=True, exist_ok=True)
prepare.annotations()
write("ami-es2004a", prepare.reference("ES2004a"), "en")
