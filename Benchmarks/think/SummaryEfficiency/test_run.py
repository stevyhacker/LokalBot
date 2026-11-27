import pathlib
import unittest

from run import server_command


class ServerCommandTests(unittest.TestCase):
    def testExtraArgumentsAreAppendedButCannotChangeTheProductionSettings(self):
        command = server_command(pathlib.Path("/s"), pathlib.Path("/m.gguf"), 9, pathlib.Path("/t"),
                                 ["--spec-type", "ngram-cache"])
        self.assertEqual(command[-2:], ["--spec-type", "ngram-cache"])
        self.assertIn("--reasoning", command)
        for owned in (["--port", "1"], ["-c=4096"], ["--reasoning", "off"], ["--cache-ram", "0"]):
            with self.assertRaises(ValueError):
                server_command(pathlib.Path("/s"), pathlib.Path("/m.gguf"), 9, pathlib.Path("/t"), owned)


if __name__ == "__main__":
    unittest.main()
