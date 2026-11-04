#!/usr/bin/env python3
"""Runs the iOS app against a stand-in computer in the iOS Simulator: pairs,
changes an action item, and sends recordings, including one queued while the
computer is away.

The recordings are a fixture queued with the Debug app's -demoQueueRecording,
because the Simulator's microphone is the host Mac's. The recorder itself isn't
tested here. Give it a Debug build for the Simulator, ad-hoc signed
(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=), because the
Keychain refuses an app with no entitlements and pairing needs it:

    python3 Companion/e2e/ios_trip.py \
        --app "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/LokalBot.app" \
        --host LinuxWindows/target/debug/examples/companion_host \
        --clip LinuxWindows/crates/lokalbot-audio/tests/data/tone-440-adts.aac \
        --out /tmp/ios-e2e

A cold Simulator can take minutes to boot, so CI runs this with --boot beside its
builds. The test waits for a boot that's still going.
"""

import argparse
import contextlib
import json
import plistlib
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

from harness import Failure, StandInHost, check, read_adts, sample_library, step, wait_until

PORT = 17892
DEVICE_NAME = "E2E iPhone"


def simctl(*args, check_result=True, timeout=180):
    result = subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, timeout=timeout)
    if check_result and result.returncode != 0:
        raise Failure(f"simctl {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def newest_iphone():
    """A Simulator of the newest iOS the machine has, so a new runner image
    doesn't need this file changed."""
    devices = json.loads(simctl("list", "devices", "available", "-j"))["devices"]
    runtimes = []
    for runtime, entries in devices.items():
        match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)-(\d+)", runtime)
        iphones = [entry for entry in entries if entry["name"].startswith("iPhone")]
        if match and iphones:
            runtimes.append(((int(match[1]), int(match[2])), iphones[0]))
    if not runtimes:
        raise Failure("This machine has no iPhone Simulator.")
    return max(runtimes, key=lambda runtime: runtime[0])[1]


class Simulator:
    def __init__(self, udid, app):
        self.udid = udid
        self.app = app
        info = plistlib.loads((app / "Info.plist").read_bytes())
        self.bundle_id = info["CFBundleIdentifier"]
        self.executable = info["CFBundleExecutable"]

    @staticmethod
    def boot_device(udid):
        simctl("bootstatus", udid, "-b", timeout=600)

    def boot(self):
        self.boot_device(self.udid)

    def install(self):
        simctl("uninstall", self.udid, self.bundle_id, check_result=False)
        simctl("install", self.udid, str(self.app))

    def launch(self, *flags):
        simctl("launch", self.udid, self.bundle_id, *flags)

    def terminate(self):
        simctl("terminate", self.udid, self.bundle_id, check_result=False)

    def storage(self):
        data = simctl("get_app_container", self.udid, self.bundle_id, "data").strip()
        return Path(data) / "Library/Application Support/LokalBot"

    def recordings(self):
        folder = self.storage() / "recordings"
        return sorted(folder.iterdir()) if folder.is_dir() else []

    def synced_records(self):
        database = (self.storage() / "companion.sqlite").as_uri()
        try:
            with contextlib.closing(sqlite3.connect(f"{database}?mode=ro", uri=True, timeout=1)) as db:
                return set(db.execute("SELECT kind, key FROM records"))
        except sqlite3.Error:
            return set()

    def save_evidence(self, out):
        simctl("io", self.udid, "screenshot", str(out / "screen.png"), check_result=False)
        log = simctl(
            "spawn", self.udid, "log", "show", "--last", "15m", "--style", "compact",
            "--predicate", f'process == "{self.executable}" OR eventMessage CONTAINS "{self.executable}"',
            check_result=False,
        )
        (out / "app-log.txt").write_text(log)

    def shut_down(self):
        simctl("shutdown", self.udid, check_result=False)


def an_open_action():
    for record in sample_library():
        if record["kind"] == "meeting":
            for action in record["body"].get("actions", []):
                if action["status"] == "open":
                    return record["key"], action["id"]
    raise Failure("The sample library has no open action item.")


def pair_and_change_an_action(simulator, host):
    step("Pair, sync the library, and mark an action item done")
    simulator.launch("-demoPairLink", host.pairing_link(), "-demoDeviceName", DEVICE_NAME)
    wait_until(
        "the computer to approve the device",
        lambda: f'Pairing "{DEVICE_NAME}"' in host.text() and "approved automatically" in host.text(),
        60,
    )
    library = {(record["kind"], record["key"]) for record in sample_library()}
    wait_until("the library to reach the phone", lambda: library <= simulator.synced_records(), 60)
    check(True, f"all {len(library)} records of the library reached the phone")
    simulator.terminate()

    # A separate launch, because a change needs the meeting to be on the phone.
    meeting, action = an_open_action()
    simulator.launch("-demoToggleAction", f"{meeting}/{action}")
    change = wait_until(
        "the action item change to reach the computer",
        lambda: next((line for line in host.text().splitlines() if line.startswith("op: ")), None),
        60,
    )
    op = json.loads(change.removeprefix("op: "))
    check(
        (op["meetingId"], op["actionId"], op["status"]) == (meeting, action, "done"),
        "the computer got the change to that action item",
    )
    simulator.terminate()


def assert_same_audio(received, clip):
    check(received.path.read_bytes() == clip.read_bytes(), "the computer's copy is byte-identical")
    read_adts(received.path)


def keep_while_the_computer_is_away(simulator, host, clip):
    step("Queue a recording while the computer is away, then bring it back")
    host.stop()
    simulator.launch("-demoQueueRecording", str(clip), "-demoRecordingTitle", "Held visit")
    held = wait_until(
        "the recording to be saved on the phone",
        lambda: [path for path in simulator.recordings() if path.stat().st_size == clip.stat().st_size],
        60,
    )
    # Long enough for an attempt to fail, which must not cost the only copy.
    time.sleep(5)
    check(held[0].read_bytes() == clip.read_bytes(), "the phone still holds it")
    simulator.terminate()
    host.start()
    simulator.launch()
    received = host.wait_for_recordings(1)
    check(received.recording["title"] == "Held visit", "its title came along")
    assert_same_audio(received, clip)
    wait_until("the phone to delete its copy", lambda: not simulator.recordings(), 60)
    check(True, "the phone deleted its copy once the computer had it")
    simulator.terminate()


def send_while_the_computer_is_there(simulator, host, clip):
    step("Queue a recording with the computer there")
    simulator.launch("-demoQueueRecording", str(clip), "-demoRecordingTitle", "Site visit")
    received = host.wait_for_recordings(2)
    check(received.recording["title"] == "Site visit", "it's a second recording")
    assert_same_audio(received, clip)
    wait_until("the phone to delete its copy", lambda: not simulator.recordings(), 60)
    simulator.terminate()


def assert_no_crashes(executable, since):
    reports = Path.home() / "Library/Logs/DiagnosticReports"
    crashes = [
        report.name
        for report in (reports.glob(f"{executable}*") if reports.is_dir() else [])
        if report.stat().st_mtime >= since
    ]
    check(not crashes, f"the app didn't crash {crashes or ''}".strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--boot", action="store_true", help="only boot the Simulator the test will use")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--host", type=Path)
    parser.add_argument("--clip", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    if args.boot:
        Simulator.boot_device(newest_iphone()["udid"])
        return 0
    if not (args.app and args.host and args.clip and args.out):
        parser.error("the test needs --app, --host, --clip and --out")

    shutil.rmtree(args.out, ignore_errors=True)
    args.out.mkdir(parents=True)
    clip = args.clip.resolve()
    device = newest_iphone()
    print(f"Using {device['name']} ({device['udid']})", flush=True)
    simulator = Simulator(device["udid"], args.app)
    host = StandInHost(args.host, args.out / "host", PORT)
    started = time.time()
    try:
        simulator.boot()
        simulator.install()
        host.start()
        pair_and_change_an_action(simulator, host)
        keep_while_the_computer_is_away(simulator, host, clip)
        send_while_the_computer_is_there(simulator, host, clip)
        assert_no_crashes(simulator.executable, started)
    except (Failure, ValueError, subprocess.SubprocessError) as error:
        print(f"FAILED: {error}", file=sys.stderr, flush=True)
        simulator.save_evidence(args.out)
        return 1
    finally:
        simulator.terminate()
        host.stop()
        if device["state"] != "Booted":
            simulator.shut_down()
    print("The iOS trip passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
