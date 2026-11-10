"""The functional UI shards are only as even as the timings they are planned from."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ui_shards', ROOT / 'Scripts/ci/ui-shards.py')
shards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shards)


class WorkingDirectory:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        self.previous = os.getcwd()
        os.chdir(self.path)

    def __exit__(self, *_):
        os.chdir(self.previous)


class CheckedInTimingTests(unittest.TestCase):
    def setUp(self):
        with WorkingDirectory(ROOT):
            plan = shards.plan()
        self.functional = plan['functional-1'] + plan['functional-2']
        self.timings = json.loads((ROOT / 'Scripts/ci/ui-durations.json').read_text())

    def test_no_timing_names_a_test_that_is_gone(self):
        self.assertEqual(sorted(set(self.timings) - set(self.functional)), [],
                         'remove timings of deleted, renamed or moved tests')

    def test_most_functional_tests_have_a_timing(self):
        # A new test may wait for its first hosted run; a suite planned mostly
        # on the 30 s guess left the two shards two minutes apart.
        untimed = [test for test in self.functional if test not in self.timings]
        self.assertLessEqual(len(untimed), len(self.functional) // 10,
                             f'refresh Scripts/ci/ui-durations.json (ui-shards.py timings): {untimed}')

    def test_the_two_shards_are_planned_within_a_minute(self):
        with WorkingDirectory(ROOT):
            plan = shards.plan()
        totals = [sum(self.timings.get(test, 30) for test in plan[phase]) for phase in ['functional-1', 'functional-2']]
        self.assertLess(abs(totals[0] - totals[1]), 60, totals)


class TimingRefreshTests(unittest.TestCase):
    def test_timings_average_passed_runs_and_keep_what_was_not_measured(self):
        plan = {'functional-1': ['A/testOne', 'A/testNew'], 'functional-2': ['B/testTwo', 'B/testKept']}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Scripts/ci').mkdir(parents=True)
            (root / 'Scripts/ci/ui-durations.json').write_text(json.dumps(
                {'A/testOne': 99, 'B/testKept': 12.5, 'Gone/testRemoved': 40}))
            (root / 'first.log').write_text(
                "Test Case '-[LokalBotUITests.A testOne]' passed (10.000 seconds).\n"
                "Test Case '-[LokalBotUITests.B testTwo]' failed (50.000 seconds).\n"
                "Test Case '-[LokalBotUITests.Smoke testElsewhere]' passed (7.000 seconds).\n")
            (root / 'second.log').write_text(
                "Test Case '-[LokalBotUITests.A testOne]' passed (20.000 seconds).\n"
                "Test Case '-[LokalBotUITests.B testTwo]' passed (30.250 seconds).\n")
            with WorkingDirectory(root), patch.object(shards, 'plan', return_value=plan):
                result = shards.timings(['first.log', 'second.log'])
        self.assertEqual(result, {'A/testOne': 15.0, 'B/testKept': 12.5, 'B/testTwo': 30.2},
                         'mean of passed runs; an unmeasured test keeps its timing; a new one waits; others drop')


if __name__ == '__main__':
    unittest.main()
