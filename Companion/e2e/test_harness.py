"""The reader decides whether a recording arrived whole, so it has to be able
to say no."""

import tempfile
import unittest
from pathlib import Path

from harness import read_adts

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


if __name__ == "__main__":
    unittest.main()
