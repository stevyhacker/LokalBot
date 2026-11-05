#!/usr/bin/env python3
"""Runs the Android app against a stand-in computer on a running emulator:
opens the QR scanner, pairs, syncs the library, opens every screen, asks a
question, records, and sends the recordings, including one cut off by a
force-stop and one made while the computer is away.

The emulator's microphone is silent, so this proves the recorder, the service
and the upload, not how speech sounds. Give it the release APK, because that's
what ships and what code shrinking can break:

    python3 Companion/e2e/android_trip.py \
        --apk Companion/android/app/build/outputs/apk/release/app-release-unsigned.apk \
        --host LinuxWindows/target/debug/examples/companion_host \
        --out /tmp/android-e2e
"""

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree
from pathlib import Path

from harness import Failure, StandInHost, check, free_port, read_adts, sample_library, step, wait_until

PACKAGE = "me.dotenv.lokalbot.companion"
RECORDING_SECONDS = 12


def adb(*args, check_result=True, timeout=120):
    result = subprocess.run(["adb", *args], capture_output=True, text=True, timeout=timeout)
    if check_result and result.returncode != 0:
        raise Failure(f"adb {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def shell(command, **kwargs):
    return adb("shell", command, **kwargs)


def signed(apk, out):
    """An unsigned release APK can't be installed, so it takes the debug key."""
    if "unsigned" not in apk.name:
        return apk
    build_tools = sorted(
        (Path(os.environ["ANDROID_HOME"]) / "build-tools").iterdir(),
        key=lambda path: [int(part) if part.isdigit() else 0 for part in path.name.split(".")],
    )[-1]
    target = out / "app-release-signed.apk"
    subprocess.run(
        [
            str(build_tools / "apksigner"), "sign",
            "--ks", str(Path.home() / ".android/debug.keystore"),
            "--ks-pass", "pass:android",
            "--out", str(target),
            str(apk),
        ],
        check=True,
    )
    return target


def nodes():
    # The dump fails while the screen is busy; the callers wait and ask again.
    shell("uiautomator dump /data/local/tmp/ui.xml", check_result=False)
    xml = adb("exec-out", "cat", "/data/local/tmp/ui.xml", check_result=False)
    try:
        root = ElementTree.fromstring(xml)
    except ElementTree.ParseError:
        return []
    found = []
    for node in root.iter("node"):
        label = node.get("text") or node.get("content-desc") or ""
        bounds = tuple(int(number) for number in re.findall(r"\d+", node.get("bounds", "")))
        if label and len(bounds) == 4:
            found.append((label, bounds))
    return found


def find(text, contains=False):
    for label, bounds in nodes():
        if label == text or (contains and text in label):
            return bounds
    return None


def wait_for(text, contains=False, timeout=45):
    return wait_until(f'"{text}" on screen', lambda: find(text, contains), timeout)


def tap(text, contains=False, timeout=45):
    left, top, right, bottom = wait_for(text, contains, timeout)
    shell(f"input tap {(left + right) // 2} {(top + bottom) // 2}")


def launch():
    shell(f"am start -n {PACKAGE}/.MainActivity")


def relaunch():
    shell(f"am force-stop {PACKAGE}")
    launch()


def ready_the_app(apk):
    step("Install the app")
    shell("input keyevent 82", check_result=False)
    adb("uninstall", PACKAGE, check_result=False)
    print(adb("install", "-r", str(apk)).strip().splitlines()[-1], flush=True)
    for permission in ("CAMERA", "RECORD_AUDIO", "POST_NOTIFICATIONS"):
        shell(f"pm grant {PACKAGE} android.permission.{permission}")
    adb("logcat", "-b", "all", "-c", check_result=False)


def open_the_scanner():
    step("Open the QR scanner")
    launch()
    tap("Pair with your computer")
    wait_for("Or paste the pairing link")
    # The camera and ML Kit start after the screen appears.
    time.sleep(5)
    assert_no_crashes()


def pair_and_sync(host):
    step("Pair through the link a QR code holds, then sync the library")
    adb("reverse", f"tcp:{host.port}", f"tcp:{host.port}")
    link = shlex.quote(host.pairing_link())
    shell(f"am start -a android.intent.action.VIEW -d {link} {PACKAGE}")
    tap("Pair")
    wait_until("the computer to approve the device", lambda: 'approved automatically' in host.text(), 45)
    tap("Meetings")
    titles = {
        record["body"]["title"]
        for record in sample_library()
        if record["kind"] == "meeting"
    }
    title = wait_until(
        "a meeting from the computer",
        lambda: next((label for label, _ in nodes() if label in titles), None),
        60,
    )
    check(True, f'the synced library shows "{title}"')
    return title


def go_to(section):
    if not find(section):
        tap("More")
    tap(section)


def open_every_screen(meeting_title):
    step("Open every screen, because code shrinking can break any of them")
    tap(meeting_title)
    tap("Transcript")
    wait_for("Quick round", contains=True)
    shell("input keyevent 4")
    for section in ("Today", "Actions", "Timeline", "People", "Projects", "Settings"):
        go_to(section)
        time.sleep(1)
    assert_no_crashes()
    go_to("Meetings")


def ask_a_question():
    step("Ask a question and read the streamed answer")
    tap("Ask")
    tap("What's overdue?")
    wait_for("cut onboarding to three steps", contains=True, timeout=60)
    check(True, "the computer's answer arrived")
    tap("Meetings")


class Take:
    """One recording, timed from outside. The test can't see the moment the
    recorder starts or ends, only the moments around it, and those bound how
    long the file can be however slow the machine is."""

    def __init__(self):
        self.earliest_start = time.monotonic()
        tap("Record a meeting")
        wait_for("Stop")
        self.latest_start = time.monotonic()

    def end(self, action):
        self.earliest_end = time.monotonic()
        action()
        self.latest_end = time.monotonic()

    def assert_audio(self, received, lost_at_most=2):
        audio = read_adts(received.path)
        least = self.earliest_end - self.latest_start - lost_at_most
        most = self.latest_end - self.earliest_start + 2
        check(audio.sample_rate == 48000 and audio.channels == 1, f"it's mono at 48 kHz ({audio})")
        check(least <= audio.seconds <= most, f"it holds {audio.seconds:.1f} s, within {least:.1f}-{most:.1f} s")


def record_and_send(host):
    step("Record, stop, and send it to the computer")
    take = Take()
    services = shell(f"dumpsys activity services {PACKAGE}")
    check("RecordingService" in services, "the recording service is running")
    time.sleep(RECORDING_SECONDS)
    take.end(lambda: tap("Stop"))
    received = host.wait_for_recordings(1)
    take.assert_audio(received)
    reported = received.recording["durationSeconds"]
    check(abs(reported - read_adts(received.path).seconds) < 3, f"the phone reported {reported:.1f} s")
    wait_for("Processing on", contains=True)
    check(True, "the phone shows the computer accepted it")


def recover_after_force_stop(host):
    step("Force-stop the app mid-recording, then reopen it")
    take = Take()
    time.sleep(RECORDING_SECONDS)
    take.end(lambda: shell(f"am force-stop {PACKAGE}"))
    time.sleep(2)
    check(not shell(f"pidof {PACKAGE}", check_result=False).strip(), "the app is gone")
    check(len(host.received()) == 1, "nothing was sent before it came back")
    launch()
    take.assert_audio(host.wait_for_recordings(2), lost_at_most=5)


def keep_while_the_computer_is_away(host):
    step("Record while the computer is away, then bring it back")
    tap("Meetings")
    host.stop()
    take = Take()
    time.sleep(5)
    take.end(lambda: tap("Stop"))
    wait_for("Waiting for", contains=True)
    check(True, "the phone says it's waiting for the computer")
    check(len(host.received()) == 2, "nothing was sent")
    host.start()
    relaunch()
    take.assert_audio(host.wait_for_recordings(3))


def assert_no_crashes():
    crashes = adb("logcat", "-d", "-b", "crash", check_result=False)
    check(f"Process: {PACKAGE}" not in crashes, "the app didn't crash")


def save_evidence(out):
    (out / "ui.txt").write_text("\n".join(f"{label} {bounds}" for label, bounds in nodes()))
    (out / "logcat.txt").write_text(adb("logcat", "-d", check_result=False, timeout=60))
    with (out / "screen.png").open("wb") as screen:
        subprocess.run(["adb", "exec-out", "screencap", "-p"], stdout=screen, check=False, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    shutil.rmtree(args.out, ignore_errors=True)
    args.out.mkdir(parents=True)
    host = StandInHost(args.host, args.out / "host", free_port())
    try:
        apk = signed(args.apk, args.out)
        host.start()
        ready_the_app(apk)
        open_the_scanner()
        meeting_title = pair_and_sync(host)
        open_every_screen(meeting_title)
        ask_a_question()
        record_and_send(host)
        recover_after_force_stop(host)
        keep_while_the_computer_is_away(host)
        assert_no_crashes()
    except (Failure, ValueError, subprocess.SubprocessError) as error:
        print(f"FAILED: {error}", file=sys.stderr, flush=True)
        save_evidence(args.out)
        crashes = adb("logcat", "-d", "-b", "crash", check_result=False)
        if crashes.strip():
            print(crashes[-6000:], file=sys.stderr)
        return 1
    finally:
        host.stop()
    print("The Android trip passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
