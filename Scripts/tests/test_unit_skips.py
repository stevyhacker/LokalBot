"""A skipped unit test must be a listed opt-in test, and the list must match the tests."""
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('unit_skips', ROOT / 'Scripts/ci/unit-skips.py')
skips = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skips)


def case(identifier, result='Passed', message=None):
    node = dict(nodeType='Test Case', nodeIdentifier=identifier + '()', result=result)
    if message:
        node['children'] = [dict(nodeType='Skip Message', name='Test skipped - ' + message)]
    return node


def tree(*cases):
    # The shape `xcresulttool get test-results tests` prints: plan, bundle, suite, cases.
    return dict(testNodes=[dict(nodeType='Test Plan', children=[dict(nodeType='Unit test bundle', children=[
        dict(nodeType='Test Suite', children=list(cases))])])])


class UnitSkipTests(unittest.TestCase):
    listed = {'LiveTests/testCallsTheAPI': 'needs a key'}

    def test_a_listed_skip_passes_and_is_reported(self):
        skipped, problems = skips.check(
            tree(case('LiveTests/testCallsTheAPI', 'Skipped', 'Set THE_KEY'), case('PlainTests/testAdds')),
            self.listed, strict=True)
        self.assertEqual(skipped, [('LiveTests/testCallsTheAPI', 'Set THE_KEY')])
        self.assertEqual(problems, [])

    def test_an_unlisted_skip_fails_with_its_reason(self):
        _, problems = skips.check(
            tree(case('ReplayTests/testRecordedAnswer', 'Skipped', 'no committed recordings')), self.listed)
        self.assertEqual(len(problems), 1)
        self.assertIn('ReplayTests/testRecordedAnswer was skipped', problems[0])
        self.assertIn('no committed recordings', problems[0])

    def test_strict_fails_when_a_listed_test_ran_or_is_gone(self):
        ran = tree(case('LiveTests/testCallsTheAPI'))
        self.assertEqual(skips.check(ran, self.listed)[1], [],
                         'a developer may set the opt-in variable on purpose')
        self.assertIn('did not skip (Passed)', skips.check(ran, self.listed, strict=True)[1][0])
        gone = tree(case('PlainTests/testAdds'))
        self.assertEqual(skips.check(gone, self.listed)[1], [], 'a run of one class leaves the rest out')
        self.assertIn('did not run', skips.check(gone, self.listed, strict=True)[1][0])

    def test_failed_and_passed_tests_are_not_skips(self):
        skipped, problems = skips.check(tree(case('PlainTests/testAdds', 'Failed'), case('PlainTests/testSubtracts')), {})
        self.assertEqual((skipped, problems), ([], []))

    def test_the_list_needs_a_reason_and_names_a_test_once(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'unit-skips.json'
            path.write_text(json.dumps(dict(groups=[dict(reason=' ', tests=['A/testB'])])))
            with self.assertRaisesRegex(ValueError, 'needs a reason'):
                skips.allowed(path)
            path.write_text(json.dumps(dict(groups=[dict(reason='x', tests=['A/testB']),
                                                    dict(reason='y', tests=['A/testB'])])))
            with self.assertRaisesRegex(ValueError, 'listed twice'):
                skips.allowed(path)


class CheckedInListTests(unittest.TestCase):
    def test_every_listed_test_exists_and_can_skip(self):
        """A renamed or deleted test must leave the list in the same change."""
        declared = {}
        for path in (ROOT / 'LokalBotTests').rglob('*.swift'):
            current = None
            text = path.read_text()
            for line in text.splitlines():
                if match := re.match(r'(?:@MainActor\s+)?(?:final )?class (\w+): XCTestCase', line):
                    current = match[1]
                elif current and (match := re.match(r'\s+(?:@MainActor\s+)?func (test\w+)\(\)', line)):
                    declared[f'{current}/{match[1]}'] = text
        for test in skips.allowed():
            self.assertTrue(test in declared, f'{test} is in unit-skips.json but not in LokalBotTests')
            self.assertTrue('XCTSkip' in declared[test], f'{test} is listed but its file never skips')

    def test_the_unit_job_and_the_local_runner_both_check_skips(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        self.assertIn('python3 Scripts/ci/unit-skips.py check .build/unit.xcresult --strict', workflow)
        self.assertIn('Scripts/ci/unit-skips.py" check', (ROOT / 'Scripts/unit-tests.sh').read_text())


if __name__ == '__main__':
    unittest.main()
