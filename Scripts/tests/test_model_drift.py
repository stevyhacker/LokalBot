"""Model drift is reported, never fatal, and each signal is detected. A case nobody answered is fatal."""
import contextlib
import io
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import unittest.mock

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("drift", SOURCE / "Scripts/ci/model-drift.py")
drift = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drift)


def call(purpose="digestFocus", content='{"a":1}', finish="stop", max_tokens=2048, reasoning=100, latency=1000):
    return {"purpose": purpose, "maxTokens": max_tokens, "content": content, "finishReason": finish,
            "completionTokens": reasoning + 50, "reasoningTokens": reasoning, "latencyMilliseconds": latency}


class ModelDriftTests(unittest.TestCase):
    def write(self, root, model, case, calls):
        folder = Path(root) / model.replace("/", "__")
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"{case}.json").write_text(json.dumps(
            {"model": model, "caseName": case, "recordedAt": "2026-09-30T03:00:00Z", "calls": calls}))

    def test_clean_run_has_no_drift(self):
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(old, "m/x", "digest-day", [call()])
            self.write(new, "m/x", "digest-day", [call()])
            self.assertEqual(drift.compare(Path(old), Path(new)), [])

    def test_each_signal_is_reported(self):
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(old, "m/x", "digest-day", [call(latency=1000) for _ in range(5)])
            self.write(new, "m/x", "digest-day", [
                call(reasoning=1500), call(content="not json"), call(latency=5000), call(), call(finish="length")])
            messages = " ".join(drift.compare(Path(old), Path(new)))
            self.assertIn("truncated", messages)
            self.assertIn("reasoning", messages)
            self.assertIn("not valid JSON", messages)
            self.assertIn("latency", messages)

    def test_one_slow_call_is_not_latency_drift(self):
        # Nightly 2026-10-01: a single GLM notes call took 4287 ms against
        # 1843 ms recorded, while the same model's recordings span 1-46 s.
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(old, "m/x", "notes-design-review", [call(latency=1843)])
            self.write(new, "m/x", "notes-design-review", [call(latency=4287)])
            self.assertEqual(drift.compare(Path(old), Path(new)), [])

    def test_latency_pools_every_case_of_a_model(self):
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            for case in ["digest-day", "ask-answer"]:
                self.write(old, "m/x", case, [call(latency=1000) for _ in range(3)])
                self.write(new, "m/x", case, [call(latency=3000) for _ in range(3)])
            messages = drift.compare(Path(old), Path(new))
            self.assertEqual(messages, ["m/x: p95 latency 3000 ms vs 1000 ms committed across 6 calls"])

    def test_an_emptied_list_is_reported(self):
        # Nightly 2026-10-01: GLM answered the unchanged notes prompt with
        # actions but `"notes": []`; the recording had five notes.
        note = {"section": "Key points", "text": "Fact.", "source": "s1"}
        action = {"text": "Task", "source": "s2"}
        recorded = json.dumps({"notes": [note] * 5, "actions": [action] * 2, "has_more": False})
        fresh = json.dumps({"notes": [], "actions": [action] * 2, "has_more": False})
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(old, "m/x", "notes-design-review", [call("notes", recorded)])
            self.write(new, "m/x", "notes-design-review", [call("notes", fresh)])
            self.assertEqual(drift.compare(Path(old), Path(new)),
                             ["m/x notes-design-review call 1 (notes): `notes` is empty; the committed answer had 5"])

    def test_a_truncated_answer_is_not_compared_for_emptied_lists(self):
        recorded = json.dumps({"notes": [{"text": "Fact."}], "actions": []})
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(old, "m/x", "notes-design-review", [call("notes", recorded)])
            self.write(new, "m/x", "notes-design-review", [call("notes", '{"notes": []', finish="length")])
            messages = " ".join(drift.compare(Path(old), Path(new)))
            self.assertNotIn("is empty", messages)

    def test_missing_committed_recording_is_a_bootstrap_not_drift(self):
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(new, "m/x", "digest-day", [call()])
            self.assertEqual(drift.compare(Path(old), Path(new)), [])

    def run_main(self, old, new):
        """(exit code, report text, GITHUB_OUTPUT lines) of the command the nightly job runs."""
        with tempfile.TemporaryDirectory() as scratch:
            report, output = Path(scratch) / "drift.md", Path(scratch) / "output"
            output.touch()
            with unittest.mock.patch.dict("os.environ", {"GITHUB_OUTPUT": str(output)}), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = drift.main([str(old), str(new), "--report", str(report)])
            return code, report.read_text(), output.read_text().split()

    def test_a_run_that_recorded_nothing_is_not_reported_as_no_drift(self):
        # Nightly 2026-11-10: OpenRouter answered every request with HTTP 401,
        # each case was saved with no calls, and the report said "No drift detected."
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            for case in ["digest-day", "ask-answer"]:
                self.write(old, "m/x", case, [call()])
                self.write(new, "m/x", case, [])
            code, report, output = self.run_main(old, new)
            self.assertEqual(code, 1)
            self.assertIn("Nothing was recorded", report)
            self.assertIn("- m/x ask-answer\n- m/x digest-day\n", report)
            self.assertNotIn("No drift detected", report)
            self.assertEqual(output, ["drift=false", "unrecorded=2"])

    def test_a_run_that_wrote_no_recordings_fails_too(self):
        # The recording test skips without a key and writes no folder at all.
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as scratch:
            self.write(old, "m/x", "digest-day", [call()])
            code, report, _ = self.run_main(old, Path(scratch) / "never-made")
            self.assertEqual(code, 1)
            self.assertIn("Nothing was recorded", report)

    def test_one_unanswered_case_is_named_beside_the_drift_of_the_rest(self):
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(old, "m/x", "digest-day", [call()])
            self.write(old, "m/x", "ask-answer", [call()])
            self.write(old, "m/y", "digest-day", [call()])
            self.write(new, "m/x", "digest-day", [call(content="not json")])
            self.write(new, "m/x", "ask-answer", [])
            code, report, output = self.run_main(old, new)
            self.assertEqual(code, 1)
            self.assertEqual(drift.unrecorded(Path(old), Path(new)), [("m/x", "ask-answer"), ("m/y", "digest-day")])
            self.assertIn("Some cases were not recorded", report)
            self.assertIn("not valid JSON", report)
            self.assertEqual(output, ["drift=true", "unrecorded=2"])

    def test_a_complete_run_still_exits_zero_with_or_without_drift(self):
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(old, "m/x", "digest-day", [call()])
            self.write(new, "m/x", "digest-day", [call()])
            self.assertEqual(self.run_main(old, new), (0, "# Model drift\n\nNo drift detected.\n",
                                                       ["drift=false", "unrecorded=0"]))
            self.write(new, "m/x", "digest-day", [call(content="not json")])
            code, report, output = self.run_main(old, new)
            self.assertEqual((code, output), (0, ["drift=true", "unrecorded=0"]))
            self.assertIn("not valid JSON", report)


if __name__ == "__main__":
    unittest.main()
