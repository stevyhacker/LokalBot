"""Cross-platform interface catalog and presentation-boundary regressions.

No model, translation API, display server or third-party Python package needed.
Run from LinuxWindows: python3 -m unittest discover -s scripts/tests
"""

import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "sync-localizations.py"
spec = importlib.util.spec_from_file_location("sync_localizations", SCRIPT)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
ROOT = sync.ROOT
CRATES = ROOT / "LinuxWindows/crates"
APP = CRATES / "lokalbot-app/src"
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')


def first_argument(source, start):
    """Read a Rust argument, retaining nested conditions but not other args."""
    depth = 0
    index = start
    while index < len(source):
        ch = source[index]
        if ch == '"':
            match = STRING.match(source, index)
            if match:
                index = match.end()
                continue
        if depth == 0 and ch in ',)':
            return source[start:index]
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        index += 1
    return source[start:]


def strings(source):
    return {json.loads(m[0]) for m in STRING.finditer(source)}


def function_body(source, start):
    start = source.index('{', start)
    depth, index = 0, start
    while index < len(source):
        if source[index] == '"':
            match = STRING.match(source, index)
            if match:
                index = match.end()
                continue
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1
    raise ValueError('Unclosed Rust function')


def source_keys():
    """Literal lookup keys plus the explicitly supported dynamic providers.

    Model prompts, IDs, user content and serialized labels are not translated
    at their source; their presentation adapters are listed here instead.
    """
    keys = set()
    paths = list(APP.rglob("*.rs")) + [
        CRATES / "lokalbot-platform/src/tray.rs",
        CRATES / "lokalbot-i18n/src/lib.rs",
        # Errors from meeting import, merge and undo, shown as they are.
        CRATES / "lokalbot-core/src/merge.rs",
        CRATES / "lokalbot-engine/src/library_ops.rs",
    ]
    calls = re.compile(r'(?:lokalbot_i18n::(?:tr|format)|crate::i18n::placeholder|\btr)\s*\(')
    for path in paths:
        source = path.read_text().split("#[cfg(test)]")[0]
        for call in calls.finditer(source):
            keys.update(strings(first_argument(source, call.end())))
    # Static settings descriptors and names are looked up as they render.
    catalog = (APP / "pages/settings/catalog.rs").read_text()
    keys.update(json.loads(m[1]) for m in re.finditer(r'title:\s*("(?:[^"\\]|\\.)*")', catalog))
    for file, constant in [
        ("pages/people.rs", "PROVENANCE"),
        ("pages/settings/meetings.rs", "DETECTED_APPS"),
        ("windows/screen_image.rs", "MISSING"),
        ("windows/screen_image.rs", "OTHER_KEY"),
        ("pages/ask/history.rs", "NEW_TITLE"),
    ]:
        source = (APP / file).read_text()
        match = re.search(r'const ' + constant + r'[^=]*=\s*("(?:[^"\\]|\\.)*")', source)
        if match:
            keys.add(json.loads(match[1]))
    source = (APP / "pages/settings/meetings.rs").read_text().split("pub fn summary_language_label")[0]
    keys.update(json.loads(m[1]) for m in re.finditer(r'\("[^"\n]+",\s*("[^"\n]+")\)', source))
    source = (APP / "component_i18n.rs").read_text().split("struct ComponentTranslations")[0]
    keys.update(json.loads(m[1]) for m in re.finditer(r'\("[^"\n]+",\s*("[^"\n]+")\)', source))
    for file in ["pages/ask/transcript.rs", "windows/quick_recall.rs"]:
        source = (APP / file).read_text()
        keys.update(strings(re.search(r'const SUGGESTIONS[^=]*=\s*\[(.*?)\];', source, re.S)[1]))
    providers = [
        ("lokalbot-core/src/settings.rs", {"label"}),
        ("lokalbot-core/src/model/activity.rs", {"label"}),
        ("lokalbot-core/src/model/outcomes.rs", {"label"}),
        ("lokalbot-audio/src/recorder.rs", {"label"}),
        ("lokalbot-agent/src/policy.rs", {"title", "detail", "confirmation_title", "confirmation_message", "confirmation_action"}),
        ("lokalbot-agent/src/session.rs", {"reasoning_name"}),
        ("lokalbot-i18n/src/lib.rs", {"count"}),
    ]
    for file, names in providers:
        source = (CRATES / file).read_text()
        for function in re.finditer(r'\bfn (\w+)\([^\n]*', source):
            if function[1] not in names:
                continue
            block = function_body(source, function.start())
            keys.update(s for s in strings(block) if s[:1].isupper() or s.startswith('{count}'))
    policy = (CRATES / "lokalbot-agent/src/policy.rs").read_text()
    keys.add(json.loads(re.search(r'PRIVATE_WORKSPACE_NOTICE[^=]*=\s*("[^"\n]+")', policy)[1]))
    return keys


class LocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = sync.read_strings(ROOT / "LokalBot/Resources/en.lproj/Localizable.strings")
        language_source = (ROOT / "LokalBot/Models/AppLanguage.swift").read_text()
        cls.codes = re.findall(r'case \w+ = "([^"]+)"', language_source)
        cls.desktop = sync.read_desktop_catalogs(cls.codes)

    def test_all_mac_languages_have_complete_desktop_catalogs(self):
        self.assertEqual(len(self.codes), 24)
        self.assertEqual(set(self.desktop), set(self.codes))
        self.assertFalse(self.shared.keys() & self.desktop['en'].keys())

    def test_generated_catalogs_are_current(self):
        self.assertEqual(sync.OUTPUT.read_text(), sync.generate(), "Run scripts/sync-localizations.py")

    def test_app_lookup_keys_are_translated(self):
        self.assertEqual(source_keys() - (self.shared.keys() | self.desktop['en'].keys()), set())

    def test_command_syntax_is_never_a_translation_key(self):
        all_keys = self.shared.keys() | self.desktop['en'].keys()
        for client in ('claude', 'codex'):
            command = f"{client} mcp add lokalbot -- {{command}} mcp"
            self.assertNotIn(command, all_keys)
            self.assertIn(f'format!("{command}")', (APP / 'pages/settings/advanced.rs').read_text())
        source = (APP / 'ui/shortcut_field.rs').read_text()
        grammar = source.split('fn format_keystroke')[1].split('#[cfg(test)]')[0]
        self.assertNotIn('lokalbot_i18n', grammar)

    def test_keyboard_hints_cannot_translate_key_names_as_ordinary_words(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            catalogs = root / 'LinuxWindows/localizations'
            catalogs.mkdir(parents=True)
            key = '{base} · Return asks · Ctrl+Return opens'
            (catalogs / 'en.json').write_text(json.dumps({key: key}))
            localized = catalogs / 'zh-Hans.json'
            localized.write_text(json.dumps({key: '{base} · Return提问 · Ctrl+Return打开'}))
            with patch.object(sync, 'ROOT', root):
                sync.read_desktop_catalogs(['en', 'zh-Hans'])
                localized.write_text(json.dumps({key: '{base} · 返回提问 · Ctrl+Return打开'}))
                with self.assertRaisesRegex(ValueError, 'changed keyboard names'):
                    sync.read_desktop_catalogs(['en', 'zh-Hans'])

    def test_invisible_characters_never_reach_the_rust_catalog(self):
        # Clippy denies a literal zero-width space, soft hyphen or word joiner.
        self.assertEqual(sync.rust_string('a\u200bb\u00adc\u2060d'), '"a\\u{200b}b\\u{ad}c\\u{2060}d"')
        self.assertIsNone(sync.INVISIBLE.search(sync.OUTPUT.read_text()))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            catalogs = root / 'LinuxWindows/localizations'
            catalogs.mkdir(parents=True)
            key = 'New lines appear as people speak.'
            (catalogs / 'en.json').write_text(json.dumps({key: key}))
            (catalogs / 'ur.json').write_text(json.dumps({key: 'نئی \u200b\u200bلکیریں'}))
            with patch.object(sync, 'ROOT', root):
                with self.assertRaisesRegex(ValueError, 'invisible character'):
                    sync.read_desktop_catalogs(['en', 'ur'])

    def test_identifiers_are_not_localized(self):
        composer = (APP / 'pages/ask/composer.rs').read_text()
        self.assertNotIn('ask-date-{label}', composer)
        for path in APP.rglob('*.rs'):
            source = path.read_text().split('#[cfg(test)]')[0]
            for call in re.finditer(r'(?:\.id|Button::new|InputState::new|\.key_context)\(', source):
                self.assertNotIn('lokalbot_i18n::', first_argument(source, call.end()), str(path))

    def test_prompt_and_storage_grammars_remain_literal(self):
        autocomplete = (APP / 'autocomplete/mod.rs').read_text()
        self.assertIn('format!("{sender}: {text}")', autocomplete)
        source = (CRATES / 'lokalbot-core/src/time.rs').read_text()
        self.assertIn('to_rfc3339_opts(SecondsFormat::Secs, true)', source)
        self.assertNotIn('lokalbot_i18n::', source.split('pub fn clock_time')[0])
        for catalog in self.desktop.values():
            self.assertNotIn('{sender}: {text}', catalog)
            self.assertNotIn('%Y-%m-%d', catalog)


if __name__ == '__main__':
    unittest.main()
