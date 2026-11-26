"""Official publish and schedule jobs stay on stevyhacker/LokalBot; fork PRs keep their checks."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
UPSTREAM = "github.repository == 'stevyhacker/LokalBot'"
UPSTREAM_REPO = "stevyhacker/LokalBot"


def workflow(name):
    return (WORKFLOWS / name).read_text(encoding="utf-8")


def job_names(text):
    return re.findall(r"^  ([a-zA-Z0-9_-]+):", text.split("\njobs:\n", 1)[1], re.M)


def job_block(text, name):
    rest = text.split(f"\n  {name}:\n", 1)[1]
    match = re.search(r"\n  [A-Za-z0-9_-]+:\n", rest)
    return rest if match is None else rest[:match.start()]


def job_if(text, name):
    header = job_block(text, name)
    lines = header.splitlines()
    for index, line in enumerate(lines):
        if not line.startswith("    if:"):
            continue
        value = line[len("    if:"):].strip()
        if value not in (">-", ">", "|"):
            return value
        collected = []
        for continuation in lines[index + 1:]:
            if continuation.startswith("      "):
                collected.append(continuation.strip())
            elif continuation.strip():
                break
        return " ".join(collected)
    return ""


class ForkFriendlyWorkflowTests(unittest.TestCase):
    def test_upstream_only_workflows_gate_every_job(self):
        for name in ["indexnow.yml", "release.yml", "claude-plugin-sync.yml", "ui-tests-macos26.yml"]:
            text = workflow(name)
            jobs = job_names(text)
            self.assertTrue(jobs, name)
            for job in jobs:
                with self.subTest(workflow=name, job=job):
                    self.assertIn(UPSTREAM, job_if(text, job))

    def test_mixed_workflows_keep_pull_request_jobs_ungated(self):
        for name, job in [
            ("ui-tests.yml", "build"),
            ("ui-tests.yml", "build-smoke"),
            ("ui-tests.yml", "shards"),
            ("app-store.yml", "archive"),
            ("google-play.yml", "check"),
            ("linux-repos.yml", "check"),
            ("winget.yml", "check"),
            ("mcp-registry.yml", "check"),
        ]:
            with self.subTest(workflow=name, job=job):
                condition = job_if(workflow(name), job)
                self.assertNotIn(UPSTREAM, condition)

    def test_mixed_workflows_gate_publish_and_schedule_jobs(self):
        for name, job in [
            ("ui-tests.yml", "changes"),
            ("ui-tests.yml", "complete"),
            ("nightly.yml", "build"),
            ("nightly.yml", "build-failed"),
            ("nightly.yml", "model-drift"),
            ("nightly.yml", "day-in-the-life-real"),
            ("nightly.yml", "scale"),
            ("nightly.yml", "model-pins"),
            ("app-store.yml", "publish"),
            ("google-play.yml", "bundle"),
            ("google-play.yml", "publish"),
            ("linux-repos.yml", "ready"),
            ("linux-repos.yml", "publish"),
            ("aur.yml", "aur"),
            ("winget.yml", "submit"),
            ("mcp-registry.yml", "bundle"),
            ("mcp-registry.yml", "publish"),
            ("windows-sign.yml", "build-windows-test"),
            ("windows-sign.yml", "sign"),
        ]:
            with self.subTest(workflow=name, job=job):
                self.assertIn(UPSTREAM, job_if(workflow(name), job))

    def test_ui_and_nightly_schedules_skip_forks_without_failing_pull_requests(self):
        schedule_or_upstream = f"github.event_name != 'schedule' || {UPSTREAM}"
        ui = workflow("ui-tests.yml")
        self.assertEqual(job_if(ui, "changes"), schedule_or_upstream)
        self.assertEqual(
            job_if(ui, "complete"),
            f"always() && ({schedule_or_upstream})",
        )
        self.assertIn("if: needs.changes.outputs.relevant == 'true'", job_block(ui, "build"))
        nightly = workflow("nightly.yml")
        self.assertEqual(job_if(nightly, "build"), schedule_or_upstream)
        self.assertIn(schedule_or_upstream, job_if(nightly, "model-drift"))
        self.assertIn(schedule_or_upstream, job_if(nightly, "model-pins"))
        self.assertIn("github.event_name != 'workflow_dispatch'", job_if(nightly, "model-drift"))
        self.assertIn("github.event_name != 'workflow_dispatch'", job_if(nightly, "model-pins"))

    def test_nightly_issue_steps_are_upstream_only(self):
        nightly = workflow("nightly.yml")
        self.assertIn(UPSTREAM, job_if(nightly, "build-failed"))
        for name in [
            "Open or update the drift issue",
            "Open or update the unchecked-drift issue",
            "Open or update the real-ASR issue",
            "Open or update the nightly issue",
            "Open or update the pins issue",
        ]:
            with self.subTest(step=name):
                step = nightly.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]
                self.assertIn(UPSTREAM, step.split("        run:", 1)[0])

    def test_aur_still_checks_pull_requests_on_forks(self):
        self.assertEqual(
            job_if(workflow("aur.yml"), "aur"),
            f"github.event_name == 'pull_request' || {UPSTREAM}",
        )

    def test_windows_sign_always_clause_still_allows_a_skipped_test_build(self):
        condition = job_if(workflow("windows-sign.yml"), "sign")
        self.assertTrue(condition.startswith("always()"))
        self.assertIn(UPSTREAM, condition)
        self.assertIn("needs.build-windows-test.result == 'skipped'", condition)

    def test_release_always_jobs_keep_always_first(self):
        release = workflow("release.yml")
        for job in ["linux-repos", "linux-windows-publish", "aur", "winget"]:
            with self.subTest(job=job):
                condition = job_if(release, job)
                self.assertTrue(condition.startswith("always()"), condition)
                self.assertIn(UPSTREAM, condition)

    def test_pull_request_release_lookups_use_upstream(self):
        linux_check = job_block(workflow("linux-repos.yml"), "check")
        self.assertIn(f"RELEASE_REPOSITORY: {UPSTREAM_REPO}", linux_check)
        self.assertIn('gh release download --repo "$RELEASE_REPOSITORY"', linux_check)
        self.assertIn('gh api "repos/$RELEASE_REPOSITORY/releases/latest"', linux_check)
        self.assertNotIn("$GITHUB_REPOSITORY", linux_check)

        winget_check = job_block(workflow("winget.yml"), "check")
        self.assertIn(f'repos/{UPSTREAM_REPO}/releases/tags/', winget_check)
        self.assertNotIn("GITHUB_REPOSITORY", winget_check)

        mcp_check = job_block(workflow("mcp-registry.yml"), "check")
        self.assertIn(f"RELEASE_REPOSITORY: {UPSTREAM_REPO}", mcp_check)
        self.assertIn('expected="https://github.com/$RELEASE_REPOSITORY/releases/download/', mcp_check)
        self.assertIn('gh api "repos/$RELEASE_REPOSITORY/releases/tags/', mcp_check)
        self.assertNotIn("$GITHUB_REPOSITORY", mcp_check)


if __name__ == "__main__":
    unittest.main()
