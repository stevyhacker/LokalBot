"""check-model-pins.py must keep finding every pin and flag a replaced asset."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_model_pins", ROOT / "Scripts/ci/check-model-pins.py")
pins = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pins)

URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/model.tar.bz2"
PIN = pins.Pin("source", URL, 10, "a" * 64)


class ModelPinTests(unittest.TestCase):
    def test_every_source_yields_its_pins(self):
        found = pins.all_pins()
        by_source = {source: [pin for pin in found if pin.source == source]
                     for source in (pins.KOKORO, pins.ONNX, pins.RUST)}
        self.assertEqual([pin.asset for pin in by_source[pins.KOKORO]], ["kokoro-multi-lang-v1_0.tar.bz2"])
        self.assertEqual(len(by_source[pins.ONNX]), 2)
        self.assertGreaterEqual(len(by_source[pins.RUST]), 7)
        for pin in found:
            self.assertRegex(pin.sha256, r"^[0-9a-f]{64}$", pin)
            self.assertGreater(pin.size, 0, pin)

    def test_a_rust_digest_held_in_a_constant_is_resolved(self):
        source = f'''const TURBO: &str =
            "{'b' * 64}";
            url: "{URL}",
            sha256: TURBO,
            size: 1_000,
        '''
        self.assertEqual(pins.rust_pins(source), [pins.Pin(pins.RUST, URL, 1000, "b" * 64)])

    def test_both_apps_pin_the_same_files(self):
        self.assertEqual(pins.disagreements(pins.all_pins()), [])

    def test_two_pins_for_one_url_must_agree(self):
        other = PIN._replace(source="other", sha256="b" * 64)
        self.assertIn("pin different files", pins.disagreements([PIN, other])[0])
        self.assertEqual(pins.disagreements([PIN, PIN._replace(source="other")]), [])

    def test_a_matching_asset_passes(self):
        self.assertIsNone(pins.compare(PIN, {"size": 10, "digest": f"sha256:{'a' * 64}"}))

    def test_a_replaced_asset_is_reported(self):
        for asset, expected in (
            ({"size": 11, "digest": f"sha256:{'a' * 64}"}, "11 served"),
            ({"size": 10, "digest": f"sha256:{'b' * 64}"}, "b" * 64),
        ):
            self.assertIn(expected, pins.compare(PIN, asset))

    def test_an_asset_without_a_digest_is_still_checked_by_size(self):
        self.assertIsNone(pins.compare(PIN, {"size": 10, "digest": None}))
        self.assertIn("11 served", pins.compare(PIN, {"size": 11, "digest": None}))

    def test_a_removed_asset_is_reported(self):
        self.assertIn("no longer has", pins.compare(PIN, None))


if __name__ == "__main__":
    unittest.main()
