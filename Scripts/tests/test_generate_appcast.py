"""The update feed is rendered whole, and never for a placeholder repository."""
import contextlib
import importlib.util
import io
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "generate_appcast.py"
TEMPLATE = ROOT / "Scripts" / "appcast.template.xml"
spec = importlib.util.spec_from_file_location("generate_appcast", SCRIPT)
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def tokens_main_fills(self):
        return set(re.findall(r'"(\{\{[A-Z_]+\}\})":', SCRIPT.read_text(encoding="utf-8")))

    def test_every_template_placeholder_gets_a_value(self):
        wanted = set(re.findall(r"\{\{[A-Z_]+\}\}", TEMPLATE.read_text(encoding="utf-8")))
        self.assertTrue(wanted)
        self.assertEqual(wanted, self.tokens_main_fills())
        rendered = appcast.render_appcast(TEMPLATE, {token: "a&b" for token in wanted})
        self.assertNotIn("{{", rendered)
        self.assertIn("a&amp;b", rendered)

    def test_a_placeholder_with_no_value_stops_the_render(self):
        with tempfile.TemporaryDirectory() as folder:
            template = Path(folder) / "appcast.template.xml"
            template.write_text(TEMPLATE.read_text(encoding="utf-8").replace(
                "<language>en</language>", "<language>{{FEED_LANGUAGE}}</language>"), encoding="utf-8")
            with self.assertRaises(SystemExit) as stopped:
                appcast.render_appcast(template, {token: "x" for token in self.tokens_main_fills()})
            self.assertIn("{{FEED_LANGUAGE}}", str(stopped.exception))

    def test_the_placeholder_repository_is_refused_before_anything_is_signed(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / "LokalBot.dmg"
            archive.write_bytes(b"not a disk image")
            output = Path(folder) / "appcast.xml"
            argv = ["generate_appcast.py", "--archive", str(archive), "--short-version", "1.0.0",
                    "--build-version", "1", "--output", str(output)]
            with patch("sys.argv", argv), patch.object(appcast, "sign_archive") as sign, \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as stopped:
                appcast.main()
            self.assertIn("--repo", str(stopped.exception))
            sign.assert_not_called()
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
