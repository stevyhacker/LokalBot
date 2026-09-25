#!/usr/bin/env python3
"""Exercise the production vendor cache gates without fetching/building runtimes."""
import os
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class VendorCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lokalbot-vendor-cache-")
        self.root = Path(self.temp.name)
        (self.root / "Scripts").mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for script in ["fetch-llama.sh", "fetch-sherpa.sh"]:
            shutil.copyfile(Path(__file__).resolve().parents[1] / script, self.root / "Scripts" / script)
        self.stub("otool", '''#!/bin/sh
printf 'minos %s\ncmd LC_RPATH\npath @loader_path (offset 12)\n' "${TEST_MINOS:-15.0}"
''')
        self.stub("file", "#!/bin/sh\necho 'Mach-O 64-bit arm64'\n")
        self.stub("curl", "#!/bin/sh\necho 'NETWORK MUST NOT RUN' >&2\nexit 99\n")
        self.stub("cmake", "#!/bin/sh\nexit 99\n")
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"])

    def tearDown(self):
        self.temp.cleanup()

    def stub(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def prepare(self, runtime):
        destination = self.root / "Vendor" / runtime
        destination.mkdir(parents=True)
        if runtime == "llama-cpp":
            marker = "v0.4.1-macos15.0-arm64-generic-loader-rpath"
            names = [
                "llama-server", "libllama.dylib", "libllama.0.dylib",
                "libggml.dylib", "libggml.0.dylib",
                "libggml-base.dylib", "libggml-base.0.dylib",
                "libggml-cpu.dylib", "libggml-cpu.0.dylib",
                "libggml-blas.dylib", "libggml-blas.0.dylib",
                "libggml-metal.dylib", "libggml-metal.0.dylib",
                "libllama-common.dylib", "libllama-common.0.dylib",
                "libllama-server-impl.dylib", "libmtmd.dylib", "libmtmd.0.dylib",
                "include/llama.h",
            ]
        else:
            marker = "v1.13.6-onnxruntime-v1.24.4-macos15.0-arm64-verified"
            names = ["sherpa-onnx-offline", "sherpa-onnx-offline-tts", "libonnxruntime.dylib", "libsherpa-onnx-c-api.dylib"]
        for name in names:
            path = destination / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\necho '--model-type --nemo-ctc-model --sense-voice-model --sense-voice-use-itn --kokoro-model --kokoro-voices --kokoro-tokens --kokoro-data-dir'\n")
            path.chmod(0o755)
        if runtime == "llama-cpp":
            manifest = destination / ".lokalbot-runtime.sha256"
            lines = []
            for path in sorted(file for file in destination.rglob("*") if file.is_file()):
                relative = "./" + path.relative_to(destination).as_posix()
                lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}\n")
            manifest.write_text("".join(lines))
            digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
            (destination / ".lokalbot-build").write_text(f"{marker}\n{digest}\n")
        else:
            (destination / ".lokalbot-build").write_text(marker + "\n")
        return destination

    def run_script(self, name, **env):
        return subprocess.run(["/bin/bash", str(self.root / "Scripts" / name)],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def test_llama_rechecks_failed_compatibility_on_every_cached_attempt(self):
        self.prepare("llama-cpp")
        for _ in range(2):
            result = self.run_script("fetch-llama.sh", TEST_MINOS="26.0")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected 15.0", result.stderr)
        self.assertEqual(self.run_script("fetch-llama.sh").returncode, 0)

    def test_missing_llama_dependency_does_not_pass_cached_marker(self):
        destination = self.prepare("llama-cpp")
        (destination / "libggml-metal.0.dylib").unlink()
        self.assertNotEqual(self.run_script("fetch-llama.sh").returncode, 0)

    def test_changed_llama_content_does_not_pass_cached_marker(self):
        destination = self.prepare("llama-cpp")
        (destination / "libllama-server-impl.dylib").write_text("changed runtime\n")
        result = self.run_script("fetch-llama.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed verification", result.stderr)

    def test_unlisted_llama_artifact_does_not_pass_cached_marker(self):
        destination = self.prepare("llama-cpp")
        extra = destination / "libunexpected.dylib"
        extra.write_text("unlisted runtime artifact\n")
        result = self.run_script("fetch-llama.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inventory does not match", result.stderr)

    def test_rewritten_manifest_is_not_accepted_without_matching_marker(self):
        destination = self.prepare("llama-cpp")
        runtime = destination / "libllama-server-impl.dylib"
        runtime.write_text("changed runtime\n")
        manifest = destination / ".lokalbot-runtime.sha256"
        manifest.write_text(manifest.read_text().replace(
            next(line for line in manifest.read_text().splitlines()
                 if line.endswith("./libllama-server-impl.dylib")),
            f"{hashlib.sha256(runtime.read_bytes()).hexdigest()}  ./libllama-server-impl.dylib"
        ))
        result = self.run_script("fetch-llama.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match its build marker", result.stderr)

    def test_sherpa_rechecks_compatibility_and_required_options(self):
        destination = self.prepare("sherpa-onnx")
        self.assertNotEqual(self.run_script("fetch-sherpa.sh", TEST_MINOS="26.0").returncode, 0)
        self.assertEqual(self.run_script("fetch-sherpa.sh").returncode, 0)
        (destination / "sherpa-onnx-offline").write_text("#!/bin/sh\necho obsolete-options\n")
        self.assertNotEqual(self.run_script("fetch-sherpa.sh").returncode, 0)


if __name__ == "__main__":
    unittest.main()
