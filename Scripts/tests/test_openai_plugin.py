"""The OpenAI plugin (ChatGPT and Codex) must stay a valid skills-only package."""

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "Distribution" / "openai-plugin"
CANONICAL_SKILL = ROOT / ".agents" / "skills" / "lokalbot-cli" / "SKILL.md"
SCHEMA = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
# Top-level keys the Agent Plugins 1.0.0 schema allows (additionalProperties: false).
ALLOWED_KEYS = {"$schema", "name", "version", "description", "author", "homepage",
                "repository", "license", "keywords", "extensions"}


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


def png_size(path: Path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big"), len(data)


class OpenAIPluginTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((PLUGIN / "plugin.json").read_text(encoding="utf-8"))
        cls.openai = cls.manifest["extensions"]["com.openai"]
        cls.interface = cls.openai["interface"]

    def test_manifest_follows_the_agent_plugins_schema(self):
        self.assertEqual(self.manifest["$schema"], SCHEMA)
        self.assertLessEqual(set(self.manifest), ALLOWED_KEYS)
        self.assertRegex(self.manifest["name"], r"^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")
        self.assertRegex(self.manifest["version"], r"^\d+\.\d+\.\d+$")
        self.assertLessEqual(len(self.manifest["description"]), 4000)
        self.assertLessEqual(set(self.manifest["author"]), {"name", "email", "url"})

    def test_skills_only_and_desktop_only(self):
        # Local MCP needs OpenAI's partner allowlist, and hooks or app references
        # can't be submitted as a ZIP, so the package is skills only.
        self.assertIs(self.openai.get("requires_local_executor"), True)
        for absent in ("mcp.json", ".mcp.json", ".app.json", "hooks", ".codex-plugin"):
            self.assertFalse((PLUGIN / absent).exists(), absent)
        for key in ("apps", "hooks"):
            self.assertNotIn(key, self.openai)
        onboarding = PLUGIN / self.openai["onboardingSkill"]
        self.assertTrue(onboarding.is_file(), onboarding)

    def test_listing_fields_fit_the_submission_limits(self):
        i = self.interface
        self.assertLessEqual(len(i["displayName"]), 30)
        self.assertLessEqual(len(i["shortDescription"]), 30)
        self.assertLessEqual(len(i["longDescription"]), 4000)
        self.assertLessEqual(len(i["developerName"]), 80)
        self.assertTrue(i["category"])
        self.assertLessEqual(len(i["capabilities"]), 20)
        for capability in i["capabilities"]:
            self.assertLessEqual(len(capability), 120, capability)
        self.assertLessEqual(len(i["defaultPrompt"]), 3)
        self.assertEqual(len(set(i["defaultPrompt"])), len(i["defaultPrompt"]))
        for prompt in i["defaultPrompt"]:
            self.assertLessEqual(len(prompt), 128, prompt)
            self.assertNotIn("@", prompt)
        for key in ("websiteURL", "supportURL", "privacyPolicyURL", "termsOfServiceURL"):
            self.assertRegex(i[key], r"^https://[^@\s]+$", key)
            self.assertLessEqual(len(i[key]), 1024)
        for key in ("brandColor", "brandColorDark"):
            self.assertRegex(i[key], r"^#[0-9A-F]{6}$", key)

    def test_icons_are_square_pngs_in_range(self):
        for key in ("composerIcon", "logo"):
            path = self.interface[key]
            self.assertTrue(path.startswith("./assets/"), path)
            width, height, size = png_size(PLUGIN / path)
            self.assertEqual(width, height)
            self.assertTrue(48 <= width <= 4096, width)
            self.assertLess(size, 5 * 1024 * 1024)

    def test_every_skill_has_a_matching_name_and_description(self):
        skills = sorted(PLUGIN.glob("skills/*/SKILL.md"))
        self.assertEqual([s.parent.name for s in skills],
                         ["lokalbot-brief", "lokalbot-cli", "lokalbot-recall", "lokalbot-setup"])
        for skill in skills:
            fields = frontmatter(skill)
            with self.subTest(skill=skill.parent.name):
                self.assertEqual(fields.get("name"), skill.parent.name)
                self.assertTrue(fields.get("description"))
                self.assertLessEqual(len(fields["description"]), 1024)

    def test_skill_copy_matches_the_bundled_skill(self):
        self.assertEqual(
            (PLUGIN / "skills" / "lokalbot-cli" / "SKILL.md").read_text(encoding="utf-8"),
            CANONICAL_SKILL.read_text(encoding="utf-8"),
            "copy .agents/skills/lokalbot-cli/SKILL.md to "
            "Distribution/openai-plugin/skills/lokalbot-cli/SKILL.md and bump "
            "version in Distribution/openai-plugin/plugin.json")

    def test_skills_carry_nothing_claude_specific_or_scanner_bait(self):
        for skill in sorted(PLUGIN.glob("skills/*/SKILL.md")):
            text = skill.read_text(encoding="utf-8")
            with self.subTest(skill=skill.parent.name):
                for claude_only in ("$ARGUMENTS", "disable-model-invocation", "argument-hint",
                                    "/lokalbot:", "/reload-plugins"):
                    self.assertNotIn(claude_only, text)
                # Shell variables read as credentials to directory scanners.
                self.assertNotRegex(text, r"\$[A-Za-z_({]")
                self.assertNotRegex(text, r"\]\(\.\./")

    def test_skills_need_no_instructions_from_outside_the_package(self):
        # OpenAI's submission rules: keep supporting files and their references
        # inside the plugin. Download pages are fine; repository docs are not.
        for skill in sorted(PLUGIN.glob("skills/*/SKILL.md")):
            text = skill.read_text(encoding="utf-8")
            with self.subTest(skill=skill.parent.name):
                self.assertNotIn("github.com/stevyhacker/lokalbot/blob/", text)
                self.assertNotIn("github.com/stevyhacker/lokalbot/tree/", text)
                self.assertNotIn("AGENT_SETUP", text)

    def test_listing_does_not_promise_nothing_leaves_the_computer(self):
        # Remote model servers the user approves do receive library content.
        manifest = json.loads((PLUGIN / "plugin.json").read_text(encoding="utf-8"))
        listing = manifest["extensions"]["com.openai"]["interface"]["longDescription"]
        self.assertNotIn("uploads nothing", listing)

    def test_codex_marketplace_points_at_the_plugin(self):
        marketplace = json.loads(
            (ROOT / ".agents" / "plugins" / "marketplace.json").read_text(encoding="utf-8"))
        entry = next(p for p in marketplace["plugins"] if p["name"] == self.manifest["name"])
        self.assertEqual(entry["source"], {"source": "local", "path": "./Distribution/openai-plugin"})
        self.assertEqual(set(entry["policy"]), {"installation", "authentication"})
        self.assertTrue(entry["category"])


if __name__ == "__main__":
    unittest.main()
