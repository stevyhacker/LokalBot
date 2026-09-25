"""Generated public copy must not turn capture provenance into identity."""

from pathlib import Path
import re
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))

import render_web  # noqa: E402


class AudioProvenanceCopyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scripts = ROOT / "Scripts"
        compare_template = (scripts / "compare.template.html").read_text(encoding="utf-8")
        guide_template = (scripts / "guide.template.html").read_text(encoding="utf-8")
        footer_template = (scripts / "footer.partial.html").read_text(encoding="utf-8")
        footer = render_web.render_footer(footer_template)
        rendered = [render_web.render_page(compare_template, page, footer)
                    for page in render_web.PAGES]
        rendered.extend(render_web.render_guide_page(guide_template, page, footer)
                        for page in render_web.GUIDES)
        cls.copy = "\n".join(rendered)

    def test_capture_tracks_are_never_presented_as_me_them_identity(self):
        forbidden = [
            r"\bMe\s*/\s*Them\b",
            r"[“\"]Me[”\"]\s+(?:and|versus)\s+[“\"]Them[”\"]",
            r"labeled\s+Me\s*/\s*Them",
            r"distinguishes you from the rest of the call",
        ]
        for pattern in forbidden:
            with self.subTest(pattern=pattern):
                self.assertIsNone(re.search(pattern, self.copy, flags=re.IGNORECASE))

    def test_copy_explains_provenance_and_identity_limit(self):
        self.assertIn("labels describe where the audio was captured, not a verified speaker identity",
                      self.copy)
        self.assertIn("source labels do not identify speakers", self.copy)
        self.assertIn("microphone and selected-app system-audio tracks", self.copy)


if __name__ == "__main__":
    unittest.main()
