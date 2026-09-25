"""Offline boundary checks; no model imports, downloads, private data, or capture."""
import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import run_transformers_ocr_benchmark as benchmark
import run_unlimited_ocr_mps as unlimited


class OCRBoundaryTests(unittest.TestCase):
    def arguments(self, *extra):
        return ["--vision-tsv", "fixture.tsv", "--model", "glm-ocr", "--output-dir", "out",
                "--revision", "a" * 40, "--corpus-kind", "synthetic", *extra]

    def test_revision_must_be_immutable_and_private_code_cannot_be_enabled(self):
        self.assertEqual(benchmark.parse_args(self.arguments()).revision, "a" * 40)
        for extra in [("--revision", "main"), ("--limit", "0"),
                      ("--corpus-kind", "private", "--allow-reviewed-remote-code"),
                      ("--isolated-worker",)]:
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    benchmark.parse_args(self.arguments(*extra))

    def test_marked_private_fixtures_cannot_run_as_synthetic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".private-screen-fixtures").touch()
            nested = root / "nested"
            nested.mkdir()
            image = nested / "fixture.png"
            text = nested / "fixture.txt"
            image.write_bytes(b"synthetic placeholder")
            text.write_text("synthetic fixture", encoding="utf-8")
            row = {"id": "1", "png_path": str(image), "vision_text_path": str(text)}
            with self.assertRaisesRegex(ValueError, "private"):
                benchmark.validate_rows([row], "synthetic")
            benchmark.validate_rows([row], "private")
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                benchmark.validate_rows([{**row, "id": "../escape"}], "private")

    def test_private_network_boundary_fails_closed_when_unavailable(self):
        with mock.patch.object(benchmark.sys, "platform", "linux"):
            with self.assertRaisesRegex(RuntimeError, "sandbox"):
                benchmark.restrict_private_network()
        with mock.patch.object(benchmark.sys, "platform", "darwin"), mock.patch("ctypes.CDLL") as loader:
            library = loader.return_value
            library.sandbox_init.return_value = 1
            with self.assertRaisesRegex(RuntimeError, "isolation failed"):
                benchmark.restrict_private_network()
            self.assertEqual(library.sandbox_init.call_args.args[0], b"(version 1)(allow default)(deny network*)")


class LegacyCustomCodeBoundaryTests(unittest.TestCase):
    revision = "b" * 40

    def arguments(self, *extra):
        return ["--model-dir", f"/cache/snapshots/{self.revision}",
                "--revision", self.revision, "--allow-reviewed-local-code",
                "--corpus-kind", "synthetic", "--image", "fixture.png",
                "--output-dir", "out", *extra]

    def test_custom_code_requires_an_immutable_reviewed_synthetic_run(self):
        self.assertEqual(unlimited.parse_args(self.arguments()).revision, self.revision)
        invalid = [
            ("--revision", "main"),
            ("--corpus-kind", "private"),
            ("--max-length", "0"),
        ]
        for replacement in invalid:
            arguments = self.arguments()
            option = replacement[0]
            if option in arguments:
                index = arguments.index(option)
                arguments[index + 1] = replacement[1]
            else:
                arguments.extend(replacement)
            with self.subTest(replacement=replacement), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    unlimited.parse_args(arguments)
        arguments = self.arguments()
        arguments.remove("--allow-reviewed-local-code")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            unlimited.parse_args(arguments)

    def test_model_directory_must_be_the_pinned_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            snapshot = root / "snapshots" / self.revision
            snapshot.mkdir(parents=True)
            self.assertEqual(unlimited.validate_model_snapshot(str(snapshot), self.revision), snapshot)
            arbitrary = root / "reviewed-model"
            arbitrary.mkdir()
            with self.assertRaisesRegex(ValueError, "snapshots"):
                unlimited.validate_model_snapshot(str(arbitrary), self.revision)
            with self.assertRaisesRegex(ValueError, "snapshots"):
                unlimited.validate_model_snapshot(str(snapshot), "c" * 40)

    def test_only_marked_synthetic_fixtures_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            fixture = root / "nested" / "fixture.png"
            fixture.parent.mkdir()
            fixture.write_bytes(b"synthetic")
            with self.assertRaisesRegex(ValueError, unlimited.SYNTHETIC_MARKER):
                unlimited.validate_synthetic_image(str(fixture))
            (root / unlimited.SYNTHETIC_MARKER).write_text("synthetic\n")
            self.assertEqual(unlimited.validate_synthetic_image(str(fixture)), fixture)
            (root / unlimited.PRIVATE_MARKER).touch()
            with self.assertRaisesRegex(ValueError, "private"):
                unlimited.validate_synthetic_image(str(fixture))

    def test_output_is_new_and_owner_only(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve() / "result"
            created = unlimited.create_private_output(str(output))
            self.assertEqual(created.stat().st_mode & 0o077, 0)
            with self.assertRaisesRegex(ValueError, "new directory"):
                unlimited.create_private_output(str(output))

    def test_custom_code_network_boundary_fails_closed(self):
        with mock.patch.object(unlimited.sys, "platform", "linux"):
            with self.assertRaisesRegex(RuntimeError, "sandbox"):
                unlimited.restrict_network()
        with mock.patch.object(unlimited.sys, "platform", "darwin"), mock.patch(
                "ctypes.CDLL") as loader:
            library = loader.return_value
            library.sandbox_init.return_value = 1
            with self.assertRaisesRegex(RuntimeError, "isolation failed"):
                unlimited.restrict_network()
            self.assertEqual(library.sandbox_init.call_args.args[0],
                             b"(version 1)(allow default)(deny network*)")


if __name__ == "__main__":
    unittest.main()
