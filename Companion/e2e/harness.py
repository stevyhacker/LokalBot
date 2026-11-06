"""What both phone end-to-end tests share: the stand-in computer, a reader for
ADTS recordings, and the checks that narrate a run in the CI log."""

import json
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

SAMPLE_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)


class Failure(Exception):
    """A check failed. The message says what went wrong for the person."""


def step(message):
    print(f"==> {message}", flush=True)


def check(condition, message):
    if not condition:
        raise Failure(message)
    print(f"    ok: {message}", flush=True)


def tap_until(description, tap, look, arrived, unchanged, timeout, again_after=5.0, every=1.0, taps=3):
    """Taps, then waits until `arrived` finds what the tap brings up on the
    screen `look` returns. An emulator under load can drop a tap, which leaves
    the screen as it was, so while `unchanged` says it still is, this taps again
    every `again_after` seconds, `taps` times in all. A screen that changed in
    any other way is left alone, so a tap the app gets wrong still fails."""
    tap()
    tapped = [time.monotonic()]

    def probe():
        screen = look()
        found = arrived(screen)
        if found:
            return found
        if len(tapped) < taps and time.monotonic() - tapped[-1] >= again_after and unchanged(screen):
            print(f"    the screen hasn't changed {time.monotonic() - tapped[-1]:.0f} s after the tap; tapping again", flush=True)
            tap()
            tapped.append(time.monotonic())
        return None

    return wait_until(description, probe, timeout, every)


def wait_until(description, probe, timeout, every=1.0):
    deadline = time.monotonic() + timeout
    while True:
        value = probe()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise Failure(f"Timed out after {timeout:.0f} s waiting for {description}.")
        time.sleep(every)


def sample_library(root=Path(__file__).resolve().parents[1]):
    return json.loads((root / "protocol/fixtures/sample-library.json").read_text())


@dataclass(frozen=True)
class Adts:
    frames: int
    sample_rate: int
    channels: int

    @property
    def seconds(self):
        return self.frames * 1024 / self.sample_rate


def read_adts(path):
    """Walks every frame header, because players only estimate an ADTS file's
    length. A killed recorder can cut the last frame short, so that one may be
    incomplete; anything else that isn't a frame makes the file invalid."""
    data = Path(path).read_bytes()
    frames = 0
    format_seen = None
    offset = 0
    while offset + 7 <= len(data):
        header = data[offset : offset + 7]
        if header[0] != 0xFF or header[1] & 0xF6 != 0xF0:
            raise ValueError(f"{path}: no ADTS frame at byte {offset}")
        rate_index = (header[2] >> 2) & 0xF
        channels = ((header[2] & 1) << 2) | (header[3] >> 6)
        length = ((header[3] & 3) << 11) | (header[4] << 3) | (header[5] >> 5)
        if rate_index >= len(SAMPLE_RATES) or channels == 0 or length < 7:
            raise ValueError(f"{path}: damaged ADTS header at byte {offset}")
        if format_seen not in (None, (rate_index, channels)):
            raise ValueError(f"{path}: the audio format changes at byte {offset}")
        format_seen = (rate_index, channels)
        if offset + length > len(data):
            break
        frames += (header[6] & 3) + 1
        offset += length
    if frames == 0:
        raise ValueError(f"{path}: no complete ADTS frames")
    return Adts(frames, SAMPLE_RATES[format_seen[0]], format_seen[1])


@dataclass(frozen=True)
class Received:
    recording: dict
    path: Path


class StandInHost:
    """LinuxWindows/crates/lokalbot-sync/examples/companion_host: the sample
    library and the real sync server, without a computer's pipeline."""

    def __init__(self, binary, folder, port, name="E2E Computer"):
        self.binary = Path(binary).resolve()
        self.folder = Path(folder)
        self.port = port
        self.name = name
        self.log = self.folder / "host.log"
        self.process = None

    def start(self):
        self.folder.mkdir(parents=True, exist_ok=True)
        before = len(self.text())
        with self.log.open("a") as log:
            self.process = subprocess.Popen(
                [
                    str(self.binary),
                    "--name", self.name,
                    "--auto-approve",
                    "--loopback",
                    "--port", str(self.port),
                    "--dir", str(self.folder / "data"),
                ],
                stdin=subprocess.PIPE,
                stdout=log,
                stderr=subprocess.STDOUT,
                text=True,
            )
        wait_until(
            "the stand-in computer to listen",
            lambda: "listening on port" in self.text()[before:] or self.process.poll() is not None,
            30,
            0.2,
        )
        if self.process.poll() is not None:
            raise Failure(f"The stand-in computer exited with {self.process.returncode}. See {self.log}.")

    def stop(self):
        if self.process is None:
            return
        try:
            self.process.stdin.write("quit\n")
            self.process.stdin.close()
            self.process.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            self.process.kill()
            self.process.wait()
        self.process = None

    def text(self):
        return self.log.read_text(errors="replace") if self.log.exists() else ""

    def pairing_link(self):
        """A new code each time, because the one from startup can expire while
        the app installs."""
        pattern = re.compile(r"^lokalbot://pair\?d=\S+", re.M)
        before = len(pattern.findall(self.text()))
        self.process.stdin.write("pair\n")
        self.process.stdin.flush()
        wait_until("a pairing code", lambda: len(pattern.findall(self.text())) > before, 10, 0.2)
        return pattern.findall(self.text())[-1]

    def received(self):
        pairs = re.findall(r"^recording: (.*)\nKept \d+ bytes at (.*)$", self.text(), re.M)
        return [Received(json.loads(recording), Path(path)) for recording, path in pairs]

    def wait_for_recordings(self, count, timeout=120):
        wait_until(f"recording {count} to reach the computer", lambda: len(self.received()) >= count, timeout)
        return self.received()[count - 1]
