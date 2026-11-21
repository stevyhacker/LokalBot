"""The comment ratchet finds every comment, ignores tool directives, deletes cleanly, and only lets counts fall."""
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('comment_ratchet', ROOT / 'Scripts/ci/comment-ratchet.py')
ratchet = importlib.util.module_from_spec(spec)
sys.modules['comment_ratchet'] = ratchet
spec.loader.exec_module(ratchet)


def texts(src, lang, directives=False):
    return [b.text for b in ratchet.blocks_in(src, lang, 'f') if b.directive == directives]


def delete_all(src, lang):
    return ratchet.delete_blocks(src, [b for b in ratchet.blocks_in(src, lang, 'f') if not b.directive])


class FindingTests(unittest.TestCase):
    def test_swift_strings_hide_slashes(self):
        src = (
            'let url = "https://lokalbot.com" // site\n'
            'let raw = #"a // b"#\n'
            'let s = "x \\("in // terp") y"\n'
            'let multi = """\n  // not a comment\n  """\n'
            '/* outer /* nested */ still */ let z = 1\n'
        )
        self.assertEqual(texts(src, 'swift'), ['// site', '/* outer /* nested */ still */'])

    def test_rust_char_literals_and_lifetimes(self):
        src = (
            "fn f<'a>(x: &'a str) -> char { '\"' } // quote\n"
            'let r = r#"// raw"#;\n'
            "let b = b'/';\n"
            '/// doc\n'
            '//! inner\n'
        )
        self.assertEqual(texts(src, 'rust'), ['// quote', '/// doc', '//! inner'])

    def test_kotlin_templates_and_chars(self):
        src = 'val s = "${"//"}"\nval c = \'"\'\n// real\n'
        self.assertEqual(texts(src, 'kotlin'), ['// real'])

    def test_js_regex_and_templates(self):
        src = 'const r = /https?:\\/\\//;\nconst t = `${"//"}`;\nconst u = "//x"; // note\n'
        self.assertEqual(texts(src, 'js'), ['// note'])

    def test_shell_hash_rules(self):
        src = (
            '#!/bin/bash\n'
            'echo "$#" ${#arr[@]} a#b\n'
            "echo '# quoted'\n"
            'cat <<EOF\n# heredoc body\nEOF\n'
            'run  # trailing\n'
        )
        self.assertEqual(texts(src, 'shell'), ['# trailing'])
        self.assertEqual(texts(src, 'shell', directives=True), ['#!/bin/bash'])

    def test_python_uses_the_tokenizer(self):
        src = 'x = "# no"  # yes\ny = f"{x!r} # no"\n'
        self.assertEqual(texts(src, 'python'), ['# yes'])

    def test_consecutive_lines_form_one_block(self):
        blocks = ratchet.blocks_in('// a\n// b\nlet x = 1\n\n// c\n', 'swift', 'f')
        self.assertEqual([(b.line, b.end_line) for b in blocks], [(1, 2), (5, 5)])


class DirectiveTests(unittest.TestCase):
    def test_tool_directives_are_not_comments(self):
        swift = '// swiftlint:disable:next force_cast\n// swift-tools-version:5.9\n// MARK: - Helpers\n'
        self.assertEqual(texts(swift, 'swift'), ['// MARK: - Helpers'])
        python = '#!/usr/bin/env python3\n# /// script\n# dependencies = []\n# ///\nimport os  # noqa: F401\n'
        self.assertEqual(texts(python, 'python'), [])

    def test_license_notices_stay(self):
        src = '// Contains code ported from Cotabby (https://example.com),\n// under the GNU AGPL v3.0.\nlet x = 1\n'
        self.assertEqual(texts(src, 'swift'), [])

    def test_clap_doc_comments_are_help_text(self):
        src = (
            '/// Not help text.\nfn helper() {}\n\n'
            '#[derive(Parser, Debug)]\n/// The CLI.\nstruct Cli {\n    /// Print JSON.\n    json: bool,\n}\n'
        )
        self.assertEqual(texts(src, 'rust'), ['/// Not help text.'])


class DeletionTests(unittest.TestCase):
    def test_whole_lines_and_trailing_comments(self):
        src = 'func f() {\n    // why\n    let a = 1 // a\n    return a\n}\n'
        self.assertEqual(delete_all(src, 'swift'), 'func f() {\n    let a = 1\n    return a\n}\n')

    def test_no_double_blank_lines_or_blank_edges(self):
        src = '//! Module notes.\n\nuse x;\n\nfn a() {}\n\n// Section\n\nfn b() {\n    // first\n\n    c();\n\n    // last\n}\n'
        self.assertEqual(delete_all(src, 'rust'), 'use x;\n\nfn a() {}\n\nfn b() {\n    c();\n}\n')

    def test_shebang_and_inline_block_comments(self):
        self.assertEqual(delete_all('#!/bin/sh\n# usage\necho hi\n', 'shell'), '#!/bin/sh\necho hi\n')
        self.assertEqual(delete_all('call(/* count */ 3, x)\n', 'js'), 'call(3, x)\n')

    def test_a_comment_only_file_becomes_empty(self):
        self.assertEqual(delete_all('// nothing here\n', 'swift'), '')


class RatchetTests(unittest.TestCase):
    def test_counts_may_only_fall_and_falls_must_be_recorded(self):
        self.assertEqual(ratchet.compare({'a.swift': 3}, {'a.swift': 3}), [])
        grew = ratchet.compare({'a.swift': 4, 'new.rs': 1}, {'a.swift': 3})
        self.assertEqual(len(grew), 2)
        self.assertIn('the baseline allows 3', grew[0])
        fell = ratchet.compare({}, {'a.swift': 3})
        self.assertIn('--update', fell[0])


if __name__ == '__main__':
    unittest.main()
