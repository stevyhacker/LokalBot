"""The Claude Code plugin must stay self-contained and match what the CLI offers."""

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
MARKETPLACE = ROOT / ".claude-plugin" / "marketplace.json"
PLUGIN = ROOT / "Distribution" / "claude-plugin"
CANONICAL_SKILL = ROOT / ".agents" / "skills" / "lokalbot-cli" / "SKILL.md"
USER_COMMANDS = ("brief", "recall", "setup")


def frontmatter(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    match = re.match(r"---\n(.*?)\n---\n", text, flags=re.DOTALL)
    if not match:
        raise AssertionError(f"{path} has no frontmatter")
    fields = {}
    for line in match.group(1).splitlines():
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields


def mcp_tool_names() -> set:
    support = ROOT / "LokalBot" / "CLISupport"
    provider = (support / "FileLibraryToolProvider.swift").read_text(encoding="utf-8")
    names = set(re.findall(r'^\s*name: "([a-z_]+)",$', provider, flags=re.MULTILINE))
    for file, pattern in (
        ("Briefing.swift", r'static let toolName = "([a-z_]+)"'),
        ("FilesAccess.swift", r'static let name = "([a-z_]+)"'),
        ("PersonalContextAccess.swift", r'static let name = "([a-z_]+)"'),
    ):
        names.update(re.findall(pattern, (support / file).read_text(encoding="utf-8")))
    return names


class ClaudePluginTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.marketplace = json.loads(MARKETPLACE.read_text(encoding="utf-8"))
        cls.manifest = json.loads(
            (PLUGIN / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
        cls.entry = next(p for p in cls.marketplace["plugins"] if p["name"] == "lokalbot")

    def test_marketplace_points_at_the_plugin_folder(self):
        # An install copies the plugin's source folder, so it must be this
        # small folder and never the repository root.
        self.assertEqual(self.entry["source"], "./Distribution/claude-plugin")
        self.assertEqual(self.manifest["name"], self.entry["name"])
        self.assertEqual(self.manifest["description"], self.entry["description"])
        self.assertFalse((ROOT / ".claude-plugin" / "plugin.json").exists(),
                         "the repository root must not be a plugin")

    def test_one_semver_version_in_the_manifest(self):
        # Installs stay on their cached copy until this string changes, and
        # the marketplace entry must not carry a second one that could drift.
        self.assertRegex(self.manifest.get("version", ""), r"^\d+\.\d+\.\d+$")
        self.assertNotIn("version", self.entry)

    def test_listing_icon_is_a_square_png_in_range(self):
        # Found by its path; naming it in the manifest or README puts the
        # submission on a policy hold ("image the plugin's code could run").
        self.assertNotIn("icon", self.manifest)
        self.assertNotIn("icon.png", (PLUGIN / "README.md").read_text(encoding="utf-8"))
        icon = PLUGIN / ".claude-plugin" / "icon.png"
        data = icon.read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        width = int.from_bytes(data[16:20], "big")
        height = int.from_bytes(data[20:24], "big")
        self.assertEqual(width, height)
        self.assertTrue(512 <= width <= 2048, width)
        self.assertLess(len(data), 2 * 1024 * 1024)

    def test_skill_copy_matches_the_bundled_skill(self):
        copy = PLUGIN / "skills" / "lokalbot-cli" / "SKILL.md"
        self.assertEqual(
            copy.read_text(encoding="utf-8"),
            CANONICAL_SKILL.read_text(encoding="utf-8"),
            "copy .agents/skills/lokalbot-cli/SKILL.md to "
            "Distribution/claude-plugin/skills/lokalbot-cli/SKILL.md and bump "
            "version in Distribution/claude-plugin/.claude-plugin/plugin.json")

    def test_user_commands_are_only_user_invoked(self):
        for name in USER_COMMANDS:
            with self.subTest(command=name):
                fields = frontmatter(PLUGIN / "skills" / name / "SKILL.md")
                self.assertTrue(fields.get("description"))
                self.assertEqual(fields.get("disable-model-invocation"), "true")

    def test_nothing_links_outside_the_plugin(self):
        # Installs and the plugin's own repository (stevyhacker/lokalbot-claude-plugin)
        # hold only this folder, so a relative link above it breaks there.
        for doc in [PLUGIN / "README.md", *sorted(PLUGIN.glob("skills/*/SKILL.md"))]:
            text = doc.read_text(encoding="utf-8")
            with self.subTest(doc=str(doc.relative_to(PLUGIN))):
                self.assertNotRegex(text, r"\]\(\.\./")

    def test_sync_workflow_copies_this_folder(self):
        workflow = (ROOT / ".github" / "workflows" / "claude-plugin-sync.yml").read_text(
            encoding="utf-8")
        self.assertIn('"Distribution/claude-plugin/**"', workflow)
        self.assertIn("rsync -a --delete --exclude .git Distribution/claude-plugin/", workflow)
        self.assertIn("git@github.com:stevyhacker/lokalbot-claude-plugin.git", workflow)
        # The deploy key must never reach a self-hosted runner.
        self.assertEqual(re.findall(r"runs-on: (.+)", workflow), ["ubuntu-24.04"])

    def test_readme_lists_every_mcp_tool(self):
        readme = (PLUGIN / "README.md").read_text(encoding="utf-8")
        tools = mcp_tool_names()
        self.assertGreaterEqual(len(tools), 15)
        for tool in sorted(tools):
            with self.subTest(tool=tool):
                self.assertIn(f"`{tool}`", readme)


if __name__ == "__main__":
    unittest.main()
