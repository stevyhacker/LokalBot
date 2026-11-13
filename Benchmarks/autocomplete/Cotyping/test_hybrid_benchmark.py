import json
from pathlib import Path
import tempfile
import unittest

from hybrid_benchmark import latency_delta, parity, prepare_judge, same_outputs


def row(ident="a", text="", **extra):
    return {"id": ident, "text": text, "prompt": "fixed prefix", "latencyMs": 10, **extra}


class NativeHybridBenchmarkTests(unittest.TestCase):
    def testParityRequiresTheExactCurrentOrCappedFallback(self):
        self.assertEqual(parity([row()], [row(text="next word")], [row(text="next")])["newlyShown"], 1)
        parity([row(text="old phrase")], [row()], [row(text="old phrase")])
        parity([row()], [row(text="рока, чак и")], [row(text="рока")])
        with self.assertRaisesRegex(ValueError, "composition"):
            parity([row()], [row(text="next word")], [row(text="next word")])
        with self.assertRaisesRegex(ValueError, "composition"):
            parity([row(text="old phrase")], [row(text="new phrase")], [row(text="new")])
        with self.assertRaisesRegex(ValueError, "prompts"):
            parity([row()], [row()], [row(prompt="changed")])
        with self.assertRaisesRegex(ValueError, "unpaired"):
            parity([row()], [], [row()])

    def testRepeatComparisonIncludesSuppressionAndSkipsOnlyCancellation(self):
        self.assertEqual(same_outputs([row()], [row(suppression="low-confidence")]), 1)
        self.assertEqual(same_outputs([row(cancelled=True)], [row(text="never evaluated")]), 0)
        with self.assertRaisesRegex(ValueError, "prompt"):
            same_outputs([row()], [row(prompt="changed")])

    def testLatencyClustersAllRepetitionsByPhrase(self):
        control = [[row("a"), row("b")]] * 4
        hybrid = [[row("a", latencyMs=15), row("b", latencyMs=15)]] * 4
        result = latency_delta(control, hybrid, {"a": "phrase", "b": "phrase"}, 100)
        self.assertEqual(result["groups"], 1)
        self.assertEqual(result["ci95"], [5, 5])
        with self.assertRaisesRegex(ValueError, "Unpaired"):
            latency_delta(control, hybrid[:1], {"a": "p", "b": "p"}, 100)

    def testJudgePacketsContainOnlyNativeOutputsAndTypedPrefix(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, output = Path(temporary), Path(temporary) / "judge"
            for arm, text in [("control", ""), ("hybrid", "next")]:
                directory = source / f"fresh-1-{arm}"
                directory.mkdir()
                (directory / "observations.jsonl").write_text(json.dumps(row(text=text)) + "\n")
            (source / "fresh-input.json").write_text(json.dumps({"cases": [{"id": "a", "prefix": "Typed "}]}))
            (source / "fresh-references.json").write_text(json.dumps({
                "a": {"phraseID": "private-phrase", "category": "work", "words": ["secret-future"]}}))
            prepare_judge(source, output, "fresh")
            protocol = json.loads((output / "protocol.json").read_text())
            self.assertEqual(protocol["counts"]["changed"], 1)
            for packet_file in (output / "batches").glob("*/packet.json"):
                packet = json.loads(packet_file.read_text())["cases"][0]
                self.assertEqual(set(packet), {"id", "prefix", "options"})
                self.assertEqual(packet["prefix"], "Typed ")
                self.assertEqual(packet["options"][0]["continuation"], "next")
                self.assertNotIn("secret-future", packet_file.read_text())
                self.assertNotIn("hybrid", packet_file.read_text())


if __name__ == "__main__":
    unittest.main()
