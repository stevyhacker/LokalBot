"""Recompute this pilot's scores and validate saved results without inference.

The streaming calculation simulates immediate playback of received PCM. It
does not measure a sound device, callback scheduling, or perceived dropouts.
"""

import hashlib
import json
from pathlib import Path
import re
import statistics
import wave

ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "results"
MATCHED_CASES = ("short", "digest", "neutral", "long")


def read(name):
    return json.loads((RESULTS / name).read_text())


def write(name, value):
    (RESULTS / name).write_text(json.dumps(value, indent=2) + "\n")


def words(text, normalized=False):
    text = text.lower().replace("’", "'")
    if normalized:
        # Explicit formatting equivalences, applied symmetrically. No names or
        # content words are corrected, and no ASR results are discarded.
        text = re.sub(r"\b2\s*:\s*30\b", "two thirty", text)
        text = text.replace("%", " percent ")
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text)


def distance(left, right):
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        current = [i]
        for j, b in enumerate(right, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (a != b)))
        previous = current
    return previous[-1]


def streaming(row):
    first = row["first_audio_s"]
    end = first
    emitted = 0.0
    extra = 0.0
    gaps = []
    previous = 0.0
    for event in row["events"]:
        arrival = event["elapsed_s"]
        assert arrival >= previous
        assert event["pcm_bytes"] > 0 and event["pcm_bytes"] % 2 == 0
        duration = event["pcm_bytes"] / (24000 * 2)
        if arrival > end + 1e-9:
            gaps.append(arrival - end)
        extra = max(extra, arrival - first - emitted)
        end = max(end, arrival) + duration
        emitted += duration
        previous = arrival
    assert abs(emitted - row["duration_s"]) < 1e-8
    assert abs(first - row["events"][0]["elapsed_s"]) < 1e-8
    assert row["elapsed_s"] >= previous
    return {
        "first_chunk_audio_s": row["events"][0]["pcm_bytes"] / 48000,
        "simulated_stall_s": sum(gaps), "simulated_stall_count": len(gaps),
        "minimum_extra_buffer_s": extra,
        "earliest_continuous_start_s_from_trace": first + extra,
    }


def main():
    breeze, smoke, kokoro, content = (
        read(name) for name in ("breeze.json", "breeze_smoke.json", "kokoro.json", "content.json"))
    assert len(breeze["rows"]) == 8 and len(smoke["rows"]) == 2
    assert len(kokoro["rows"]) == 6 and len(content["rows"]) == 14
    summary = {"breeze": [], "kokoro": []}
    for row in breeze["rows"] + smoke["rows"]:
        assert row.get("done", {}).get("type") == "speech.audio.done"
        assert not row.get("errors") and not row.get("exception")
        assert row["server_returncode"] is None
        assert row["samples"] > 0 and row["clipped_fraction"] == 0
        timeline = streaming(row)
        if row in breeze["rows"]:
            summary["breeze"].append({
                "id": row["id"], "phase": row["phase"],
                "first_audio_s": row["first_audio_s"], "elapsed_s": row["elapsed_s"],
                "audio_s": row["duration_s"], "rtf": row["rtf"], **timeline,
                "process_lifetime_peak_phys_gib": row["memory_after"]["lifetime_max_phys_footprint"] / 2**30,
            })
    for row in kokoro["rows"]:
        assert row["returncode"] == 0
        assert row["samples"] > 0 and row["clipped_fraction"] == 0
        summary["kokoro"].append({
            "id": row["id"], "elapsed_s": row["elapsed_s"],
            "audio_s": row["duration_s"], "rtf": row["rtf"],
            "process_lifetime_peak_phys_gib": row["memory"]["lifetime_max_phys_footprint"] / 2**30,
        })

    hashes = {}
    for report, prefix in ((breeze, "breeze"), (smoke, "breeze_smoke"), (kokoro, "kokoro")):
        for row in report["rows"]:
            suffix = f"_{row['phase']}" if prefix != "kokoro" else ""
            path = ROOT / "audio" / f"{prefix}_{row['id']}{suffix}.wav"
            with wave.open(str(path)) as wav:
                assert wav.getframerate() == row["sample_rate"] == 24000
                assert wav.getsampwidth() == 2 and wav.getnchannels() == 1
                assert wav.getnframes() == row["samples"]
                assert len(wav.readframes(wav.getnframes())) == row["samples"] * 2
            hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    summary["same_seed_audio_identical"] = hashes["breeze_short_cold.wav"] == hashes["breeze_short_warm.wav"]
    summary["different_seed_audio_differs"] = hashes["breeze_short_warm_seed43.wav"] != hashes["breeze_short_warm.wav"]
    warm = [row for row in summary["breeze"] if row["phase"] != "cold"]
    summary["breeze_warm_median_first_audio_s"] = statistics.median(row["first_audio_s"] for row in warm)
    summary["breeze_warm_weighted_rtf"] = sum(row["elapsed_s"] for row in warm) / sum(row["audio_s"] for row in warm)
    summary["breeze_warm_trace_continuous_start_range_s"] = [
        min(row["earliest_continuous_start_s_from_trace"] for row in warm),
        max(row["earliest_continuous_start_s_from_trace"] for row in warm),
    ]
    summary["streaming_limits"] = (
        "Offline simulation from client event times, with constant-rate PCM playback. "
        "Extra buffer is the minimum for these traces and excludes device scheduling and future jitter. "
        "Breeze memory peaks are process-lifetime high-water marks, shared across requests.")

    content_rows = {row["file"]: row for row in content["rows"]}
    aggregate = {"matched_cases": list(MATCHED_CASES), "normalization": [
        "Lowercase, apostrophe normalization, punctuation ignored.",
        "2:30 and two thirty are equivalent; % and percent are equivalent, applied to both sides.",
        "Use one warm seed-42 Breeze result and one Kokoro result per case; exclude reference, duplicate short runs, directed-only case, and numeric case from the matched aggregate.",
    ], "models": {}}
    for engine in ("breeze", "kokoro"):
        rows = []
        for case in MATCHED_CASES:
            filename = f"{engine}_{case}{'_warm' if engine == 'breeze' else ''}.wav"
            row = content_rows[filename]
            score = {"file": filename, "id": case}
            for normalized, label in ((False, "raw"), (True, "normalized")):
                reference = words(row["reference"], normalized)
                hypothesis = words(row["transcript"], normalized)
                score[label + "_edits"] = distance(reference, hypothesis)
                score[label + "_reference_words"] = len(reference)
            assert score["raw_edits"] == row["edits"]
            rows.append(score)
        aggregate["models"][engine] = {"rows": rows}
        for label in ("raw", "normalized"):
            edits = sum(row[label + "_edits"] for row in rows)
            count = sum(row[label + "_reference_words"] for row in rows)
            aggregate["models"][engine][label] = {"edits": edits, "reference_words": count, "wer": edits / count}
    aggregate["limits"] = (
        "ASR agreement is not human-rated TTS quality. Both long transcriptions render "
        "next step as next steps; this may be a shared recognition ambiguity. Numeric/name "
        "cases should be listened to; brand spelling is not evidence of a pronunciation error.")
    summary["content"] = aggregate
    write("summary.json", summary)
    write("audio_sha256.json", hashes)
    write("validation.json", {
        "status": "passed", "breeze_full_requests": 8, "breeze_smoke_requests": 2,
        "kokoro_files": 6, "content_transcripts": 14, "verified_wav_files": len(hashes),
        "checks": ["Request success and completion", "Nonempty mono 24 kHz PCM16 WAVs",
                   "WAV frame counts agree with result metadata", "Streaming PCM byte totals and ordered timestamps",
                   "No clipped samples reported", "Raw ASR scores recomputed from saved transcripts",
                   "Matched-case aggregate excludes duplicated prompts", "Audio SHA256 manifest written"],
        "limits": "Artifact consistency checks only; no human listening, UI tests, or installed-app integration test.",
    })
    print(json.dumps({k: v for k, v in summary.items() if k not in ("breeze", "kokoro", "content")}, indent=2))
    print(json.dumps({k: {m: v[m] for m in ("raw", "normalized")} for k, v in aggregate["models"].items()}, indent=2))


if __name__ == "__main__":
    main()
