import os
from pathlib import Path
import tempfile
import unittest

from remote_comparison import candidate_env, markdown, read_env_file, remote_engine_args, via_openrouter
from quality_replay import score


class RemoteComparisonTests(unittest.TestCase):
    def test_each_replay_sees_only_its_own_key(self):
        keys = {"CEREBRAS_API_KEY": "c-key", "MODULAR_API_KEY": "m-key"}
        base = {"PATH": "/bin", "CEREBRAS_API_KEY": "shell", "LOKALBOT_REPLAY_API_KEY": "stale"}
        self.assertEqual(candidate_env(base, keys), {"PATH": "/bin"})
        self.assertEqual(candidate_env(base, keys, {"apiKeyEnv": "MODULAR_API_KEY"}),
                         {"PATH": "/bin", "MODULAR_API_KEY": "m-key"})

    def test_openrouter_route_pins_the_provider_and_keeps_its_fields(self):
        candidate = {"id": "c", "label": "Qwen on Cerebras", "baseURL": "https://api.cerebras.ai/v1",
                     "model": "qwen-3.8-27b", "apiKeyEnv": "CEREBRAS_API_KEY", "extraBody": {"top_k": 20},
                     "openRouterModel": "qwen/qwen3.8-27b", "openRouterProvider": "cerebras"}
        routed = via_openrouter(candidate)
        self.assertEqual(routed["baseURL"], "https://openrouter.ai/api/v1")
        self.assertEqual(routed["model"], "qwen/qwen3.8-27b")
        self.assertEqual(routed["apiKeyEnv"], "OPENROUTER_API_KEY")
        self.assertEqual(routed["extraBody"], {"top_k": 20, "provider": {
            "order": ["cerebras"], "allow_fallbacks": False, "data_collection": "deny"}})
        self.assertEqual(candidate["extraBody"], {"top_k": 20}, "the direct route is left unchanged")
        self.assertIsNone(via_openrouter({**candidate, "openRouterProvider": None}))
        self.assertNotIn("--completions-chat", remote_engine_args(routed))
        chat = via_openrouter({**candidate, "openRouterChat": True})
        self.assertEqual(remote_engine_args(chat)[-1], "--completions-chat")
        own_body = via_openrouter({**candidate, "openRouterExtraBody": {}})
        self.assertEqual(set(own_body["extraBody"]), {"provider"}, "a direct-only field stays off the OpenRouter route")

    def test_env_file_skips_comments_blanks_and_quotes(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "keys.env"
            path.write_text("# comment\nCEREBRAS_API_KEY=\"abc\"\nMODULAR_API_KEY=\n\nOTHER = x=y\n")
            os.chmod(path, 0o600)
            self.assertEqual(read_env_file(path), {"CEREBRAS_API_KEY": "abc", "OTHER": "x=y"})

    def test_retries_and_tail_latency_are_reported(self):
        references = {"a": {"phraseID": "p", "category": "work", "typed": "", "words": ["tomorrow"]}}
        observations = [{"id": "a", "text": "tomorrow", "latencyMs": 310, "attempts": 3}]
        overall = score(observations, references)["overall"]
        self.assertEqual(overall["retries"], 2)
        self.assertEqual(overall["p90Ms"], 310)

    def test_failed_engine_still_appears_in_the_report(self):
        summary = {"skipped": {"x": "X_KEY is not set"},
                   "suites": {"corpus": {"y": {"label": "Y", "returncode": 1}}}}
        report = markdown(summary)
        self.assertIn("| Y | failed (exit 1) |", report)
        self.assertIn("Skipped x: X_KEY is not set.", report)


if __name__ == "__main__":
    unittest.main()
