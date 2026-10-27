"""Keep the interface translation tables aligned and format-safe."""

import json
from pathlib import Path
import re
import unittest


APP = Path(__file__).resolve().parents[2] / "LokalBot"
RESOURCES = APP / "Resources"
LANGUAGES = sorted(path.parent.stem for path in RESOURCES.glob("*.lproj/Localizable.strings"))
# Literals in these views that predate the view-literal check and still have
# no catalog entry. Translating one means deleting its line here.
UNTRANSLATED_VIEW_LITERALS = Path(__file__).with_name("untranslated_view_literals.json")
# SwiftUI looks these first arguments up in the catalog; StatTile passes its
# label on as a LocalizedStringKey.
CATALOG_CALLS = re.compile(r"(?<![\w.])(Text|Button|Label|StatTile)\(|\.(navigationTitle)\(")
CATALOG_ARGUMENT = {"Text": None, "Button": None, "Label": None, "navigationTitle": None, "StatTile": "label"}
# Proper names and symbols that read the same in every language.
INTENTIONAL_VIEW_LITERALS = {
    "Anthropic API", "Apple Intelligence", "EmbeddingGemma 2", "Kokoro 82M", "LokalBot ", "Ollama", "⌘K",
}
ARGUMENT_LABEL = re.compile(r"\s*(\w+)\s*:(?!:)")
NEXT_TOKEN = re.compile(r"\s*(\?\?|.)", re.S)
RAW_LITERAL = re.compile(r'#+"')
KEYED_PROPERTY = re.compile(r"LocalizedStringKey\((\w+)\)")
SWIFT_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}
FORMAT_SPECIFIER = r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDiuUxXoOfeEgGcCsSpaA]"


def read_strings(language):
    entries = {}
    for line in (RESOURCES / f"{language}.lproj" / "Localizable.strings").read_text().splitlines():
        if not line.strip() or line.startswith("//"):
            continue
        match = re.fullmatch(r'("(?:[^"\\]|\\.)*") = ("(?:[^"\\]|\\.)*");', line)
        if match is None:
            raise ValueError(f"Invalid translation entry: {line}")
        key, value = map(json.loads, match.groups())
        if key in entries:
            raise ValueError(f"Duplicate translation key: {key}")
        entries[key] = value
    return entries


def swift_literal(source, index):
    """Read the string literal at source[index].

    Returns (parts, end): parts alternate text and None for each `\\(...)`
    interpolation. Multi-line and raw literals return None parts; they are not
    catalog keys in these views.
    """
    if source.startswith('"""', index):
        return None, source.index('"""', index + 3) + 3
    if source[index] == "#":
        hashes = RAW_LITERAL.match(source, index).end() - index - 1
        closing = '"' + "#" * hashes
        return None, source.index(closing, index + hashes + 1) + len(closing)
    parts, text, index = [], [], index + 1
    while source[index] != '"':
        if source[index] == "\\":
            escape = source[index + 1]
            if escape == "(":
                parts.append("".join(text))
                text, index = [], swift_parenthesized(source, index + 1)
                parts.append(None)
                continue
            if escape == "u":
                end = source.index("}", index)
                text.append(chr(int(source[index + 3:end], 16)))
                index = end + 1
                continue
            text.append(SWIFT_ESCAPES[escape])
            index += 2
            continue
        text.append(source[index])
        index += 1
    parts.append("".join(text))
    return parts, index + 1


def swift_parenthesized(source, index):
    """Return the index after the parenthesis that closes source[index]."""
    depth = 0
    while True:
        character = source[index]
        if character == '"' or RAW_LITERAL.match(source, index):
            index = swift_literal(source, index)[1]
            continue
        depth += character in "([{"
        depth -= character in ")]}"
        index += 1
        if depth == 0:
            return index


def swift_without_comments(source):
    """Blank comments so commented-out code and doc examples are not scanned."""
    result, index = [], 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            result.append(" " * (end - index))
            index = end
        elif source.startswith("/*", index):
            end = source.index("*/", index) + 2
            result.append(re.sub(r"[^\n]", " ", source[index:end]))
            index = end
        elif source[index] == '"' or RAW_LITERAL.match(source, index):
            end = swift_literal(source, index)[1]
            result.append(source[index:end])
            index = end
        else:
            result.append(source[index])
            index += 1
    return "".join(result)


def call_arguments(source, index):
    """Split the call arguments that start at source[index] (after its "(").

    Yields (label, [(previous token, literal parts, next token)]) for each
    top-level argument, with the string literals found at its top level.
    """
    literals, depth, previous = [], 0, "("
    match = ARGUMENT_LABEL.match(source, index)
    label = match[1] if match else None
    index = match.end() if match else index
    while True:
        character = source[index]
        if character == '"' or RAW_LITERAL.match(source, index):
            parts, index = swift_literal(source, index)
            following = NEXT_TOKEN.match(source, index)[1]
            if depth == 0 and parts is not None:
                literals.append((previous, parts, following))
            previous = "literal"
            continue
        if depth == 0 and character in ",)":
            yield label, literals
            if character == ")":
                return
            match = ARGUMENT_LABEL.match(source, index + 1)
            label, literals, previous = (match[1] if match else None), [], "("
            index = match.end() if match else index + 1
            continue
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        if depth == 0 and not character.isspace():
            previous = "??" if source.startswith("??", index - 1) else character
        index += 1


def scan_view_literals(sources, keys):
    """Literals SwiftUI shows untranslated in the given {name: Swift source}.

    Returns (missing, verbatim) sets of (name, literal), with each
    interpolation shown as \\(…). Missing literals have no catalog key. A
    literal joined with `+` or used as a `??` fallback makes the argument a
    String, which SwiftUI shows verbatim even when the catalog has the key.
    """
    formatted_keys = [key for key in keys if "%" in key]
    missing, verbatim = set(), set()

    def has_key(parts):
        if len(parts) == 1:
            return parts[0] in keys
        pattern = re.compile("".join(
            FORMAT_SPECIFIER if part is None else re.escape(part.replace("%", "%%"))
            for part in parts))
        return any(pattern.fullmatch(key) for key in formatted_keys)

    def translatable(parts):
        shown = "".join("\\(…)" if part is None else part for part in parts)
        letters = re.search(r"[^\W\d_]", "".join(filter(None, parts)))
        return shown if letters and shown not in INTENTIONAL_VIEW_LITERALS else None

    for name, source in sources.items():
        source = swift_without_comments(source)
        for call in CATALOG_CALLS.finditer(source):
            wanted = CATALOG_ARGUMENT[call[1] or call[2]]
            for position, (label, literals) in enumerate(call_arguments(source, call.end())):
                if label != wanted or (wanted is None and position > 0):
                    continue
                for previous, parts, following in literals:
                    shown = translatable(parts)
                    if shown is None:
                        continue
                    if previous == "??" or following == "+":
                        verbatim.add((name, shown))
                    elif previous in "(?:" and following in "),:" and not has_key(parts):
                        missing.add((name, shown))
        # A String property shown through LocalizedStringKey(property) needs
        # its default in the catalog too, like `var title = "Needs Attention"`.
        for property_name in set(KEYED_PROPERTY.findall(source)):
            declaration = re.compile(r"\b(?:var|let)\s+" + property_name + r"\s*(?::\s*String\s*)?=\s*(?=\")")
            for match in declaration.finditer(source):
                parts = swift_literal(source, match.end())[0]
                shown = translatable(parts) if parts else None
                if shown is not None and not has_key(parts):
                    missing.add((name, shown))
    return missing, verbatim


def view_literal_problems():
    views = APP / "Views"
    sources = {path.relative_to(views).as_posix(): path.read_text() for path in sorted(views.rglob("*.swift"))}
    return scan_view_literals(sources, set(read_strings("en")))


class LocalizationTests(unittest.TestCase):
    def test_supported_languages_and_catalogs_stay_in_sync(self):
        declared = set(re.findall(r'case \w+ = "([^"]+)"', (APP / "Models/AppLanguage.swift").read_text()))
        self.assertEqual(set(LANGUAGES), declared)
        self.assertTrue({"en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt", "id", "ur",
                         "ru", "de", "ja", "pcm", "ar-EG", "mr", "vi", "te", "sw", "ha", "ko",
                         "zh-Hant", "it", "sr-Latn"} <= declared)

    def test_languages_have_matching_nonempty_entries(self):
        english = read_strings("en")
        for language in LANGUAGES:
            with self.subTest(language=language):
                translated = read_strings(language)
                self.assertEqual(english.keys(), translated.keys())
                self.assertTrue(all(value.strip() for value in translated.values()))
        self.assertEqual(read_strings("zh-Hans")["App language"], "界面语言")
        # English must be available even when the Mac uses another language.
        self.assertEqual(english["Settings"], "Settings")

    def test_format_arguments_survive_translation(self):
        english = read_strings("en")
        placeholders = re.compile(r"%(?:\d+\$)?(?:lld|ld|[diufgs@%])")
        for language in LANGUAGES:
            translated = read_strings(language)
            for key, source in english.items():
                with self.subTest(language=language, key=key):
                    self.assertEqual(placeholders.findall(source), placeholders.findall(translated[key]))

    def test_view_literals_have_catalog_entries(self):
        # Catalog checks above only compare keys that already exist; new view
        # copy without a key ships in English to every other language.
        missing, verbatim = view_literal_problems()
        recorded = json.loads(UNTRANSLATED_VIEW_LITERALS.read_text())
        for kind, found, advice in [
            ("missing", missing, "Add these to en.lproj and every other catalog, or use Text(verbatim:) for content"),
            ("verbatim", verbatim, "Interpolate instead of using + or ??, so SwiftUI looks the text up"),
        ]:
            known = {(name, literal) for name, literals in recorded[kind].items() for literal in literals}
            with self.subTest(kind=kind):
                self.assertEqual(sorted(found - known), [], advice)
                self.assertEqual(sorted(known - found), [],
                                 f"Translated or removed: delete these from {UNTRANSLATED_VIEW_LITERALS.name}")

    def test_view_literal_scan_finds_untranslated_copy(self):
        source = """
        struct Sample: View {
            var title = "Needs Attention"
            var body: some View {
                Text(LocalizedStringKey(title))
                Text("Update Digest")
                Text(verbatim: "LokalBot")
                Text("Updated " + time)
                Text(owner ?? "Owner unclear")
                Button(busy ? "Writing…" : "Write Digest") {}
                Label("Away \\(duration)", systemImage: "moon")
                StatTile(icon: "clock", value: value, label: "tracked")
                Text(name).help("Not scanned \\(name)")
                // Text("Commented out")
                Text("Done")
                Text("•")
            }
        }
        """
        missing, verbatim = scan_view_literals({"Sample.swift": source}, {"Done", "Writing…"})
        self.assertEqual({literal for _, literal in missing},
                         {"Needs Attention", "Update Digest", "Write Digest", "Away \\(…)", "tracked"})
        self.assertEqual({literal for _, literal in verbatim}, {"Updated ", "Owner unclear"})
        # An interpolation matches whichever format specifier the key uses.
        self.assertEqual(scan_view_literals({"Sample.swift": 'Text("Away \\(duration)")'}, {"Away %@"}),
                         (set(), set()))

    def test_line_breaks_and_direction_controls(self):
        english = read_strings("en")
        # Direction belongs to the view environment, never hidden overrides or
        # marks in copy. Machine translation most often inserts LRM, RLM and ALM.
        overrides = re.compile("[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]")
        for language in LANGUAGES:
            for key, value in read_strings(language).items():
                with self.subTest(language=language, key=key):
                    self.assertEqual(english[key].count("\n"), value.count("\n"))
                    self.assertIsNone(overrides.search(value))


if __name__ == "__main__":
    unittest.main()
