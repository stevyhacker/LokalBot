"""The reader decides whether a recording arrived whole, so it has to be able
to say no. The Android trip taps again and answers Android's dialogs for the
emulator's sake, so it has to leave the app's own failures alone."""

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import android_trip
import harness
from harness import Failure, read_adts, tap_until

CLIP = Path(__file__).resolve().parents[2] / "LinuxWindows/crates/lokalbot-audio/tests/data/tone-440-adts.aac"


class ReadAdtsTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.path = Path(folder.name) / "clip.aac"
        self.clip = CLIP.read_bytes()

    def read(self, data):
        self.path.write_bytes(data)
        return read_adts(self.path)

    def test_counts_every_frame_of_a_whole_file(self):
        audio = self.read(self.clip)
        self.assertEqual((audio.frames, audio.sample_rate, audio.channels), (45, 44100, 1))
        self.assertAlmostEqual(audio.seconds, 1.045, places=3)

    def test_a_file_cut_inside_its_last_frame_keeps_the_frames_before_it(self):
        whole = self.read(self.clip)
        self.assertEqual(self.read(self.clip[:-1]).frames, whole.frames - 1)

    def test_half_a_file_counts_half_the_frames(self):
        whole = self.read(self.clip)
        self.assertLess(self.read(self.clip[: len(self.clip) // 2]).frames, whole.frames * 0.6)

    def test_damage_in_the_middle_is_refused(self):
        middle = len(self.clip) // 2
        with self.assertRaises(ValueError):
            self.read(self.clip[:middle] + b"\0" * 64 + self.clip[middle:])

    def test_a_file_that_is_not_audio_is_refused(self):
        with self.assertRaises(ValueError):
            self.read(b"not audio at all, just some bytes")

    def test_an_empty_file_is_refused(self):
        with self.assertRaises(ValueError):
            self.read(b"")


class Clock:
    """Time that passes only when the code under test sleeps."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def quietly(test):
    def run(self, *args):
        with mock.patch.object(harness, "time", Clock()), contextlib.redirect_stdout(io.StringIO()):
            return test(self, *args)

    return run


class Screen:
    """A screen a tap moves on from, unless the emulator drops the tap."""

    def __init__(self, drops=0, lands_on="after"):
        self.drops = drops
        self.lands_on = lands_on
        self.now = "before"
        self.taps = 0

    def tap(self):
        self.taps += 1
        if self.taps > self.drops:
            self.now = self.lands_on

    def look(self):
        return self.now

    def tap_until(self):
        return tap_until(
            "the next screen",
            self.tap,
            self.look,
            arrived=lambda now: now == "after" and now,
            unchanged=lambda now: now == "before",
            timeout=45,
        )


class TapUntilTests(unittest.TestCase):
    @quietly
    def test_a_tap_that_lands_is_not_repeated(self):
        screen = Screen()
        self.assertEqual(screen.tap_until(), "after")
        self.assertEqual(screen.taps, 1)

    @quietly
    def test_a_dropped_tap_is_tapped_again_after_five_seconds(self):
        screen = Screen(drops=1)
        self.assertEqual(screen.tap_until(), "after")
        self.assertEqual(screen.taps, 2)
        self.assertGreaterEqual(harness.time.monotonic(), 5)

    @quietly
    def test_a_screen_that_never_changes_gets_three_taps_and_fails(self):
        screen = Screen(drops=99)
        with self.assertRaisesRegex(Failure, "Timed out after 45 s waiting for the next screen"):
            screen.tap_until()
        self.assertEqual(screen.taps, 3)

    @quietly
    def test_a_screen_that_went_somewhere_else_is_not_tapped_again(self):
        screen = Screen(lands_on="somewhere else")
        with self.assertRaises(Failure):
            screen.tap_until()
        self.assertEqual(screen.taps, 1)


def at(row):
    return (0, row * 100, 1080, row * 100 + 80)


WELCOME = [("Welcome to LokalBot", at(3)), ("Pair with your computer", at(10)), ("Try the sample library", at(11))]
SCANNER = [("Pair with your computer", at(1)), ("Or paste the pairing link", at(15))]
MEETINGS = [("Weekly sync", at(2)), ("Meetings", at(22)), ("Ask", at(23))]
ASK_STILL_LOADING = [("Meetings", at(22)), ("Ask", at(23))]
SYSTEM_UI_STUCK = [("System UI isn't responding", at(8)), ("Close app", at(9)), ("Wait", at(10))]
APP_STUCK = [("LokalBot isn't responding", at(8)), ("Close app", at(9)), ("Wait", at(10))]


class Phone:
    """An emulator whose screen moves on when a label is pressed, as `goes`
    says, unless it drops the press."""

    def __init__(self, screen, goes, drops=0):
        self.screen = screen
        self.goes = goes
        self.drops = drops
        self.pressed = []

    def nodes(self):
        return self.screen

    def press(self, bounds):
        label = next(label for label, where in self.screen if where == bounds)
        self.pressed.append(label)
        if self.drops:
            self.drops -= 1
        else:
            self.screen = self.goes[label]

    def tap(self, text, then):
        with mock.patch.object(android_trip, "nodes", self.nodes), mock.patch.object(android_trip, "press", self.press):
            android_trip.tap(text, then=then)


class AndroidTapTests(unittest.TestCase):
    @quietly
    def test_a_dropped_tap_on_the_welcome_screen_is_tapped_again(self):
        phone = Phone(WELCOME, {"Pair with your computer": SCANNER}, drops=1)
        phone.tap("Pair with your computer", then="Or paste the pairing link")
        self.assertEqual(phone.pressed, ["Pair with your computer"] * 2)

    @quietly
    def test_a_tab_still_in_view_after_its_tap_landed_is_not_tapped_again(self):
        phone = Phone(MEETINGS, {"Ask": ASK_STILL_LOADING})
        with self.assertRaises(Failure):
            phone.tap("Ask", then="What's overdue?")
        self.assertEqual(phone.pressed, ["Ask"])

    @quietly
    def test_system_ui_not_responding_is_answered_with_wait(self):
        phone = Phone(SYSTEM_UI_STUCK, {"Wait": WELCOME, "Pair with your computer": SCANNER})
        phone.tap("Pair with your computer", then="Or paste the pairing link")
        self.assertEqual(phone.pressed, ["Wait", "Pair with your computer"])

    @quietly
    def test_the_app_not_responding_fails_the_run(self):
        phone = Phone(APP_STUCK, {})
        with self.assertRaisesRegex(Failure, "LokalBot isn't responding"):
            phone.tap("Pair with your computer", then="Or paste the pairing link")
        self.assertEqual(phone.pressed, [])


class NotRespondingTests(unittest.TestCase):
    def answer(self, found):
        pressed = []
        with contextlib.redirect_stdout(io.StringIO()):
            answered = android_trip.answered_not_responding(found, pressed.append)
        return answered, pressed

    def test_a_typographic_apostrophe_is_the_same_dialog(self):
        dialog = [("Pixel Launcher isn\u2019t responding", at(8)), ("Close app", at(9)), ("Wait", at(10))]
        self.assertEqual(self.answer(dialog), (True, [at(10)]))

    def test_the_app_saying_something_isnt_responding_is_not_the_dialog(self):
        message = [("Your computer isn't responding", at(4)), ("Wait", at(5))]
        self.assertEqual(self.answer(message), (False, []))

    def test_an_ordinary_screen_is_left_alone(self):
        self.assertEqual(self.answer(WELCOME), (False, []))


if __name__ == "__main__":
    unittest.main()
