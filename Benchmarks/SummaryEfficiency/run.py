#!/usr/bin/env python3
"""Replay copied transcripts through production Swift extraction, locally only.

Run with uv run --no-project Benchmarks/SummaryEfficiency/run.py --help.
Results contain private meeting data; keep --output outside the repository.
"""

import argparse
import copy
import json
import pathlib
import plistlib
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


REPO = pathlib.Path(__file__).resolve().parents[2]


def replace_test_root(value, root):
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(root))
    if isinstance(value, list):
        return [replace_test_root(item, root) for item in value]
    if isinstance(value, dict):
        return {key: replace_test_root(item, root) for key, item in value.items()}
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transcript", type=pathlib.Path, required=True)
    parser.add_argument("--model", type=pathlib.Path, required=True)
    parser.add_argument("--runtime", type=pathlib.Path, default=REPO / "Vendor/llama-cpp/llama-server")
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    output = (args.output or pathlib.Path(tempfile.mkdtemp(prefix="lokalbot-notes-benchmark-"))).resolve()
    if output == REPO or REPO in output.parents:
        parser.error("Private replay outputs must be outside the repository.")
    output.mkdir(parents=True, exist_ok=True)
    if any((output / run).exists() for run in ("cold", "warm")):
        parser.error("Choose a fresh output directory; replay checkpoints must not bypass inference.")

    source = args.transcript.resolve()
    inputs = output / "input"
    inputs.mkdir(exist_ok=True)
    shutil.copy2(source, inputs / "transcript.json")
    if (source.parent / "notes.md").exists():
        shutil.copy2(source.parent / "notes.md", inputs / "notes.md")
    transcript = json.loads((inputs / "transcript.json").read_text())
    segments = transcript["segments"]

    if not args.skip_build:
        with (output / "build.log").open("w") as log:
            subprocess.run([str(REPO / "Scripts/unit-tests.sh"), "MeetingNotesReplayTests"],
                           cwd=REPO, stdout=log, stderr=subprocess.STDOUT, check=True)
    derived = subprocess.run([str(REPO / "Scripts/unit-tests.sh"), "--derived-data-path"],
                             check=True, capture_output=True, text=True).stdout.strip()
    products = pathlib.Path(derived) / "Build/Products"
    candidates = list(products.glob("LokalBot_*macosx*-arm64.xctestrun"))
    if not candidates:
        parser.error("Build the non-UI tests first, or omit --skip-build.")
    test_run = max(candidates, key=lambda path: path.stat().st_mtime)
    test_template = replace_test_root(plistlib.loads(test_run.read_bytes()), products)

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    token = secrets.token_hex(32)
    token_file = output / "server.token"
    token_file.write_text(token)
    token_file.chmod(0o600)
    endpoint = f"http://127.0.0.1:{port}"
    report = {
        "durationSeconds": max((segment["end"] for segment in segments), default=0),
        "words": sum(len(segment["text"].split()) for segment in segments),
        "segments": len(segments), "model": args.model.name, "runs": [],
    }
    started = time.monotonic()
    with (output / "server.log").open("w") as server_log:
        server = subprocess.Popen([
            str(args.runtime.resolve()), "-m", str(args.model.resolve()),
            "--host", "127.0.0.1", "--port", str(port), "-c", "32768", "-ngl", "99",
            "--jinja", "--no-webui", "--api-key-file", str(token_file),
            "--cache-ram", "2048", "--reasoning", "on",
        ], stdout=server_log, stderr=subprocess.STDOUT)
        try:
            while True:
                if server.poll() is not None or time.monotonic() - started > 60:
                    raise RuntimeError("Local model startup failed; inspect the private server.log.")
                try:
                    request = urllib.request.Request(endpoint + "/health", headers={"Authorization": "Bearer " + token})
                    with urllib.request.urlopen(request, timeout=1) as response:
                        if json.load(response).get("status") == "ok":
                            break
                except (urllib.error.URLError, TimeoutError):
                    time.sleep(0.2)
            startup = time.monotonic() - started
            request = urllib.request.Request(endpoint + "/props", headers={"Authorization": "Bearer " + token})
            with urllib.request.urlopen(request, timeout=5) as response:
                props = json.load(response)
                report["runtime"] = props.get("build_info")
                report["slots"] = props.get("total_slots")
            report["modelStartupSeconds"] = startup

            for name in ("cold", "warm"):
                manifest = output / f"{name}.json"
                manifest.write_text(json.dumps({
                    "transcript": str(inputs / "transcript.json"), "output": str(output / name),
                    "endpoint": endpoint + "/v1", "tokenFile": str(token_file),
                }, indent=2))
                config = copy.deepcopy(test_template)
                for configuration in config["TestConfigurations"]:
                    configuration["TestTargets"] = [target for target in configuration["TestTargets"]
                                                      if target["BlueprintName"] == "LokalBotTests"]
                    for target in configuration["TestTargets"]:
                        target.setdefault("EnvironmentVariables", {})["LOKALBOT_NOTES_REPLAY_MANIFEST"] = str(manifest)
                        target["OnlyTestIdentifiers"] = ["MeetingNotesReplayTests/testLocalQwenReplay"]
                        target["TestTimeoutsEnabled"] = False
                config_file = output / f"{name}.xctestrun"
                config_file.write_bytes(plistlib.dumps(config))
                with (output / f"{name}-test.log").open("w") as log:
                    run = subprocess.run([
                        "xcodebuild", "-quiet", "-xctestrun", str(config_file),
                        "-destination", "platform=macOS,arch=arm64",
                        "-only-testing:LokalBotTests/MeetingNotesReplayTests", "-skip-testing:LokalBotUITests",
                        "-resultBundlePath", str(output / f"{name}.xcresult"), "test-without-building",
                    ], cwd=REPO, stdout=log, stderr=subprocess.STDOUT)
                metrics_path = output / name / "notes-generation-metrics.json"
                metrics = json.loads(metrics_path.read_text()) if metrics_path.exists() else {}
                measured = metrics.get("elapsedSeconds")
                result = {"name": name, "testExitCode": run.returncode, "metrics": metrics,
                          "totalSeconds": measured + (startup if name == "cold" else 0) if measured is not None else None}
                report["runs"].append(result)
                (output / "measurements.json").write_text(json.dumps(report, indent=2))
                print(json.dumps({"run": name, "outcome": metrics.get("outcome"),
                                  "seconds": result["totalSeconds"], "testExitCode": run.returncode}), flush=True)
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            token_file.unlink(missing_ok=True)
    print(f"Private results: {output}")
    return int(any(run["testExitCode"] for run in report["runs"]))


if __name__ == "__main__":
    raise SystemExit(main())
