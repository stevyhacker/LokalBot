import importlib.util
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("checker", SOURCE / "Scripts/ci/check-capture-recordings.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def trace(title, version=1, url=None, app="Google Chrome"):
    snapshot = {"text": "", "windowTitle": title}
    if url:
        snapshot["sourceURL"] = url
    return {"header": {"scrubberVersion": version},
            "events": [{"app": {"localizedName": app}, "read": {"snapshot": snapshot}}]}


class CaptureTraceCheckerTests(unittest.TestCase):
    def test_scrubbed_trace_passes(self):
        self.assertEqual(checker.violations(trace("Meet - bcd-fghj-klm", url="https://meet.google.com/bcd-fghj-klm"), "t"), [])

    def test_unscrubbed_text_fails(self):
        self.assertTrue(checker.violations(trace("Quarterly revenue review"), "t"))

    def test_non_ascii_letters_fail(self):
        self.assertTrue(checker.violations(trace("Sstnk Đrđm"), "t"))

    def test_wrong_scrubber_version_fails(self):
        self.assertTrue(checker.violations(trace("bcd", version=None), "t"))

    def test_unknown_app_name_must_be_scrubbed(self):
        self.assertTrue(checker.violations(trace("bcd", app="Acme Payroll"), "t"))

    def test_unscrubbed_bundle_ids_fail(self):
        def with_bundle(bundle):
            value = trace("bcd")
            value["events"][0]["app"]["bundleIdentifier"] = bundle
            value["events"].append({"query": "audioProcesses", "processes": [
                {"name": "Google Chrome Helper", "bundleID": "com.google.Chrome.helper"}]})
            return value
        self.assertTrue(checker.violations(with_bundle("com.acme.payroll"), "t"))
        for allowed in ("com.google.Chrome", "com.apple.dt.Xcode", "cbm.xcmf.pvbrfll"):
            self.assertEqual(checker.violations(with_bundle(allowed), "t"), [], allowed)

    def test_nested_meeting_hosts_pass_in_any_order(self):
        original = checker.HOSTS
        try:
            for order in (["zoom.us", "app.zoom.us"], ["app.zoom.us", "zoom.us"]):
                checker.HOSTS = order
                self.assertEqual(checker.violations(trace("bcd", url="https://app.zoom.us/j/8412"), "t"), [], order)
        finally:
            checker.HOSTS = original


if __name__ == "__main__":
    unittest.main()
