#!/usr/bin/env python3
"""Fail a unit-test run whose skipped tests are not the listed opt-in tests.

A skipped test reports nothing, so a test that starts skipping (a fixture that
was never committed, a helper that turns a failure into a skip) looks like a
passing one. Scripts/ci/unit-skips.json names every test that may skip, with
the reason; any other skipped test fails the run.

  unit-skips.py check RESULT.xcresult            # after a local run
  unit-skips.py check RESULT.xcresult --strict   # hosted CI, whole bundle

--strict also fails when a listed test did not skip or did not run, so the
list cannot outlive its tests. It is for runs where no opt-in variable is set
and the whole unit bundle ran. A local run of one class, or one with an opt-in
variable set on purpose, runs without it.
"""
import argparse
import collections
import json
from pathlib import Path
import subprocess
import sys

LIST = Path(__file__).with_name('unit-skips.json')


def allowed(path=LIST):
    """Test identifier -> reason. Rejects an entry without a reason or listed twice."""
    result = {}
    for group in json.loads(Path(path).read_text())['groups']:
        reason = group.get('reason', '').strip()
        if not reason or not group.get('tests'):
            raise ValueError(f'Every group in {Path(path).name} needs a reason and tests')
        for test in group['tests']:
            if test in result:
                raise ValueError(f'{test} is listed twice in {Path(path).name}')
            result[test] = reason
    return result


def results(node):
    """(identifier, result, skip message) for every test case in an xcresulttool tree."""
    if isinstance(node, dict):
        if node.get('nodeType') == 'Test Case':
            messages = [child.get('name', '') for child in node.get('children', [])
                        if child.get('nodeType') == 'Skip Message']
            yield (node['nodeIdentifier'].removesuffix('()'), node['result'],
                   '; '.join(messages).removeprefix('Test skipped - '))
        for child in node.get('children', node.get('testNodes', [])):
            yield from results(child)


def check(tree, listed, strict=False):
    """Returns (skipped tests as (identifier, message), problems)."""
    cases = list(results(tree))
    outcome = {identifier: result for identifier, result, _ in cases}
    skipped = [(identifier, message) for identifier, result, message in cases if result == 'Skipped']
    problems = [f'{identifier} was skipped and is not in {LIST.name}: {message or "no reason given"}'
                for identifier, message in skipped if identifier not in listed]
    if strict:
        for identifier in sorted(listed):
            if identifier not in outcome:
                problems.append(f'{identifier} is in {LIST.name} and did not run: was it renamed or removed?')
            elif outcome[identifier] != 'Skipped':
                problems.append(f'{identifier} is in {LIST.name} and did not skip ({outcome[identifier]}): '
                                'take it off the list')
    return skipped, problems


def read(result_bundle):
    return json.loads(subprocess.check_output(
        ['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(result_bundle), '--compact']))


def main(arguments):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('mode', choices=['check'])
    parser.add_argument('result', help='an .xcresult bundle')
    parser.add_argument('--strict', action='store_true',
                        help='every listed test must have run and skipped (hosted CI)')
    options = parser.parse_args(arguments)
    listed = allowed()
    skipped, problems = check(read(options.result), listed, strict=options.strict)
    reasons = collections.Counter(listed.get(identifier, 'NOT LISTED') for identifier, _ in skipped)
    print(f'{len(skipped)} unit tests skipped.')
    for reason, count in reasons.most_common():
        print(f'  {count:3}  {reason}')
    for problem in problems:
        print(f'::error::{problem}' if options.strict else f'error: {problem}', file=sys.stderr)
    return 1 if problems else 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
