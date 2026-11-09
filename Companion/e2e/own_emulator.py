#!/usr/bin/env python3
"""Boots a throwaway emulator, runs a command against it and removes it, on a
machine other people use at the same time, such as the self-hosted CI runner:

    python3 Companion/e2e/own_emulator.py -- python3 Companion/e2e/android_trip.py \\
        --apk Companion/android/app/build/outputs/apk/release/app-release-unsigned.apk \\
        --host LinuxWindows/target/debug/examples/companion_host \\
        --out /tmp/android-e2e

An adb server connects to every emulator on ports up to 5585 when it starts, so
two people's would find each other's. This emulator sits above that range, and
its adb server has a port of its own and doesn't go looking. The command reaches
both through ANDROID_ADB_SERVER_PORT and ANDROID_SERIAL.

It needs ANDROID_HOME with SYSTEM_IMAGE installed, and access to /dev/kvm.
"""

import argparse
import os
import random
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

from harness import Failure, free_port, step, wait_until

SYSTEM_IMAGE = "system-images;android-36;google_apis;x86_64"
PROFILE = "pixel_7"
AVD = "own"
# The emulator takes even console ports up to 5682 and uses the next one for adb.
CONSOLE_PORTS = range(5600, 5682, 2)
BOOT_TIMEOUT = 300
EMULATOR_OPTIONS = "-no-window -no-snapshot -no-audio -no-boot-anim -gpu swiftshader_indirect -accel on".split()
# What android-emulator-runner does on GitHub's runners, so the test sees the same.
AFTER_BOOT = (
    "input keyevent 82",
    "settings put global window_animation_scale 0.0",
    "settings put global transition_animation_scale 0.0",
    "settings put global animator_duration_scale 0.0",
)


def is_free(port):
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def free_console_port():
    for port in random.sample(CONSOLE_PORTS, len(CONSOLE_PORTS)):
        if is_free(port) and is_free(port + 1):
            return port
    raise Failure(f"No free console port between {CONSOLE_PORTS[0]} and {CONSOLE_PORTS[-1]}.")


def environment(sdk, work):
    console = free_console_port()
    tools = [sdk / "platform-tools", sdk / "emulator", sdk / "cmdline-tools/latest/bin"]
    return {
        **os.environ,
        "PATH": os.pathsep.join([*map(str, tools), os.environ["PATH"]]),
        "ANDROID_AVD_HOME": str(work / "avd"),
        "ANDROID_ADB_SERVER_PORT": str(free_port()),
        # Below the first emulator's port, it makes the server look at none.
        "ADB_LOCAL_TRANSPORT_MAX_PORT": "0",
        "ANDROID_SERIAL": f"emulator-{console}",
    }


def adb(env, *args, timeout=60):
    return subprocess.run(["adb", *args], env=env, capture_output=True, text=True, timeout=timeout, check=False)


def wait_for_boot(emulator, env, log):
    def booted():
        if emulator.poll() is not None:
            raise Failure(f"The emulator exited with {emulator.returncode}:\n{log.read_text(errors='replace')[-4000:]}")
        try:
            return adb(env, "shell", "getprop", "sys.boot_completed", timeout=10).stdout.strip() == "1"
        except subprocess.TimeoutExpired:
            return False

    wait_until("the emulator to boot", booted, BOOT_TIMEOUT, 2)


def stop(emulator, env):
    try:
        adb(env, "emu", "kill", timeout=15)
        emulator.wait(timeout=30)
    except subprocess.TimeoutExpired:
        emulator.kill()
        emulator.wait()


def run_on_own_emulator(command, sdk, work):
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        raise Failure("This user can't use /dev/kvm, and the emulator is too slow without it.")
    env = environment(sdk, work)
    serial = env["ANDROID_SERIAL"]
    console = serial.removeprefix("emulator-")
    step(f"Boot {serial} with an adb server on port {env['ANDROID_ADB_SERVER_PORT']}")
    (work / "avd").mkdir()
    subprocess.run(
        ["avdmanager", "create", "avd", "--force", "-n", AVD, "--package", SYSTEM_IMAGE, "--device", PROFILE],
        input="no\n", text=True, env=env, stdout=subprocess.DEVNULL, check=True,
    )
    subprocess.run(["adb", "start-server"], env=env, check=True)
    log = work / "emulator.log"
    with log.open("w") as output:
        emulator = subprocess.Popen(
            ["emulator", "-port", console, "-avd", AVD, *EMULATOR_OPTIONS],
            env=env, stdout=output, stderr=subprocess.STDOUT,
        )
    try:
        wait_for_boot(emulator, env, log)
        for setting in AFTER_BOOT:
            adb(env, "shell", setting)
        return subprocess.run(command, env=env, check=False).returncode
    finally:
        stop(emulator, env)
        adb(env, "kill-server")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="+", help="what to run once the emulator is up, after --")
    args = parser.parse_args()
    # A cancelled CI job ends with SIGTERM, and the emulator shouldn't outlive it.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    with tempfile.TemporaryDirectory(prefix="own-emulator-", dir=os.environ.get("RUNNER_TEMP")) as work:
        try:
            return run_on_own_emulator(args.command, Path(os.environ["ANDROID_HOME"]), Path(work))
        except (Failure, subprocess.SubprocessError) as error:
            print(f"FAILED: {error}", file=sys.stderr, flush=True)
            return 1


if __name__ == "__main__":
    sys.exit(main())
