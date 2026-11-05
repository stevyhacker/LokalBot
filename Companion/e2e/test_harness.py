"""The reader decides whether a recording arrived whole, so it has to be able
to say no."""

import socket
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import own_emulator
from harness import free_port, read_adts

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


class PortTests(unittest.TestCase):
    def test_a_free_port_can_be_taken(self):
        with socket.socket() as server:
            server.bind(("127.0.0.1", free_port()))

    def test_a_taken_port_is_not_free(self):
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen()
            self.assertFalse(own_emulator.is_free(server.getsockname()[1]))

    def test_other_adb_servers_never_look_at_the_emulator_ports(self):
        # adb servers scan up to 5585; the emulator refuses anything above 5682.
        self.assertGreater(min(own_emulator.CONSOLE_PORTS), 5585)
        self.assertLess(max(own_emulator.CONSOLE_PORTS) + 1, 5682)
        self.assertTrue(all(port % 2 == 0 for port in own_emulator.CONSOLE_PORTS))

    def test_a_console_port_needs_its_adb_port_free_too(self):
        with (
            mock.patch.object(own_emulator, "CONSOLE_PORTS", (5600, 5602)),
            mock.patch.object(own_emulator, "is_free", lambda port: port != 5601),
        ):
            self.assertEqual(own_emulator.free_console_port(), 5602)

    def test_no_free_console_port_is_a_failure_that_says_so(self):
        with mock.patch.object(own_emulator, "is_free", lambda port: False):
            with self.assertRaisesRegex(own_emulator.Failure, "console port"):
                own_emulator.free_console_port()


if __name__ == "__main__":
    unittest.main()
