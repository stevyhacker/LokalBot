#!/usr/bin/env python3
"""Plan disjoint XCTest shards and verify executed tests plus every matrix PNG.

The two functional shards are balanced from Scripts/ci/ui-durations.json; a
test without a timing counts as 30 s. Refresh the file from passing runs with
`ui-shards.py timings functional-1.log functional-2.log [more logs]`.
"""
import collections
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import time

VISUAL = 'RedesignUITests/testWorkspaceVisualMatrix'
REDUCED = 'RedesignUITests/testReducedMotionWorkspaceRemainsOperable'
# Flows with the host's background work running (replayed trace, file audio,
# model stub) run only in their own shard.
BACKGROUND = 'BackgroundFlowUITests'
SMOKE = [
    'RedesignUITests/testHighContrastKeepsActionsAccessible',
    'MainWindowUITests/testMeetingWaveformExposesSliderAndSupportsKeyboardSeeking',
    'AgentModeUITests',
    'RedesignUITests/testAgentApprovalDescribesEffectAndDenialAndStopReachTheController',
    'RedesignUITests/testActionSearchPreservesSelectionAndCommandClickSelectsSeveral',
    'MainWindowUITests/testMultiMeetingThreadCompletionRequiresConfirmation',
    'MainWindowUITests/testActionThreadSourceCanBeSeparatedAndRestored',
]
SIZES = ['1000x700', '1180x740', '1440x900']
ROUTES = ['today', 'actions', 'meeting', 'transcript', 'review', 'timeline', 'search', 'ask',
          'settings', 'models', 'dictation', 'autocomplete', 'agent']
# The complete suite runs on two macOS runners after the build, about 30 and 35
# minutes each (2026-11-18 timings). Every runner is another job GitHub can fail
# to place when hosted macOS capacity is short, and a failed-jobs-only rerun
# repeats one group, not the suite. Each phase still writes its own report, so
# verify() checks it as before. Reduce Motion runs last so its preference can't
# reach another phase even if restoring it fails.
GROUPS = {
    'runner-1': ['smoke', 'functional-1', 'reduced-motion'],
    'runner-2': ['functional-2', 'visual', 'background'],
}
REDUCED_MOTION_DEFAULTS = [('com.apple.universalaccess', 'reduceMotion'),
                           ('org.localhost.lokalbot.redesign-ci', 'requiresReducedMotion')]


def inventory(root=Path('.')):
    # XCTest methods are parameterless Swift methods in final XCTestCase classes.
    # Reject new test syntax rather than silently omitting it from the inventory.
    result = []
    for path in sorted((root / 'LokalBotUITests').rglob('*.swift')):
        current = None
        for line in path.read_text().splitlines():
            match = re.match(r'final class (\w+): XCTestCase', line)
            if match:
                current = match[1]
            match = re.match(r'\s+func (test\w+)\(\)', line)
            if match:
                if not current:
                    raise ValueError(f'Unrecognized test class in {path}')
                result.append(current + '/' + match[1])
            elif re.search(r'\bfunc test\w+|@Test\b', line):
                raise ValueError(f'Unrecognized test declaration: {path}: {line}')
    if not result or len(result) != len(set(result)):
        raise ValueError('Empty or duplicate XCTest inventory')
    return sorted(result)


def plan():
    tests = inventory()
    smoke = [test for test in tests if any(test == item or test.startswith(item + '/') for item in SMOKE)]
    if not all(any(test == item or test.startswith(item + '/') for test in smoke) for item in SMOKE):
        raise ValueError('A required smoke selector no longer exists')
    background = [test for test in tests if test.startswith(BACKGROUND + '/')]
    remainder = set(tests) - set(smoke) - set(background) - {REDUCED, VISUAL}
    timings = json.loads(Path('Scripts/ci/ui-durations.json').read_text())
    shards = [[], []]
    totals = [0, 0]
    for test in sorted(remainder, key=lambda test: (-timings.get(test, 30), test)):
        index = totals.index(min(totals))
        shards[index].append(test)
        totals[index] += timings.get(test, 30)
    return dict(smoke=smoke, background=background, **{'reduced-motion': [REDUCED],
                               'functional-1': shards[0], 'functional-2': shards[1]},
                **{f'visual-{size}': [VISUAL] for size in SIZES})


def timings(logs):
    """Mean duration of each functional-shard test over the given shard logs.

    The logs are `functional-1.log` and `functional-2.log` from the
    `ui-results-runner-*` artifacts of passing UI Tests runs. A test the
    logs do not hold keeps the timing it had.
    """
    pattern = re.compile(r"Test Case '-\[LokalBotUITests\.(\w+) (\w+)\]' passed \(([\d.]+) seconds\)")
    seen = collections.defaultdict(list)
    for log in logs:
        for match in pattern.finditer(Path(log).read_text(errors='replace')):
            seen[f'{match[1]}/{match[2]}'].append(float(match[3]))
    phases = plan()
    functional = phases['functional-1'] + phases['functional-2']
    known = json.loads(Path('Scripts/ci/ui-durations.json').read_text())
    measured = {test: round(sum(seen[test]) / len(seen[test]), 1) for test in functional if test in seen}
    return {test: measured.get(test, known.get(test)) for test in sorted(functional)
            if test in measured or test in known}


def test_results(node):
    if isinstance(node, dict):
        if node.get('nodeType') == 'Test Case':
            yield node['nodeIdentifier'].removesuffix('()'), node['result']
        for child in node.get('children', node.get('testNodes', [])):
            yield from test_results(child)


def selected_tests(selector):
    selector = selector.removeprefix('LokalBotUITests/')
    selected = [test for test in inventory() if test == selector or test.startswith(selector + '/')]
    if not selected:
        raise ValueError(f'Unknown UI test selector: {selector}')
    return selected


def gate(build, first, second, selector=''):
    if build != 'success' or first != 'success':
        raise ValueError('Build and the critical or focused tests must succeed')
    if selector:
        selected_tests(selector)
        if second != 'skipped':
            raise ValueError('Focused runs must skip the second runner')
    elif second != 'success':
        raise ValueError('Every phase on both runners must succeed')


def grouped_phases():
    """Every planned phase the runner groups execute, `visual` standing for its sizes."""
    return [phase for members in GROUPS.values() for member in members
            for phase in ([f'visual-{size}' for size in SIZES] if member == 'visual' else [member])]


def reduce_motion(enabled):
    for domain, key in REDUCED_MOTION_DEFAULTS:
        subprocess.run(['defaults', 'write', domain, key, '-bool', 'true' if enabled else 'false'], check=True)


def execute(phase, selected=None):
    if phase in GROUPS:
        # A failed phase doesn't stop the rest of its group.
        codes = [execute(member) for member in GROUPS[phase]]
        return next((code for code in codes if code), 0)
    if phase == 'visual':
        # Each size keeps its own result, log and report, so verify() and the
        # evidence look exactly as they did with one runner per size. A failed
        # size doesn't stop the others.
        codes = [execute(f'visual-{size}') for size in SIZES]
        return next((code for code in codes if code), 0)
    if os.environ.get('CI') != 'true':
        raise ValueError('Shard execution is hosted-only')
    # Phases that share a runner must not inherit each other's test environment
    # or accessibility preferences, so both are put back after each phase.
    runs = {path: path.read_bytes() for path in Path('.build/dd/Build/Products').glob('*.xctestrun')}
    try:
        if phase == 'reduced-motion':
            reduce_motion(True)
        return run_phase(phase, selected)
    finally:
        if phase == 'reduced-motion':
            reduce_motion(False)
        for path, data in runs.items():
            path.write_bytes(data)


def run_phase(phase, selected):
    phases = plan()
    tests = selected_tests(selected) if phase == 'single' else phases[phase]
    folder = Path('.build/ui-results')
    folder.mkdir(parents=True, exist_ok=True)
    if phase.startswith('visual-') or phase == 'single':
        for run in Path('.build/dd/Build/Products').glob('*.xctestrun'):
            value = plistlib.loads(run.read_bytes())
            for config in value['TestConfigurations']:
                for target in config['TestTargets']:
                    env = target.setdefault('EnvironmentVariables', {})
                    env['LOKALBOT_VISUAL_SIZE'] = phase.removeprefix('visual-') if phase.startswith('visual-') else ''
                    env['LOKALBOT_CAPTURE_MODE'] = os.environ.get('CAPTURE_MODE', 'ready')
                    env['LOKALBOT_VISUAL_EVIDENCE'] = str((folder / 'captures').resolve())
            run.write_bytes(plistlib.dumps(value))
    if phase == 'background':
        for run in Path('.build/dd/Build/Products').glob('*.xctestrun'):
            value = plistlib.loads(run.read_bytes())
            for config in value['TestConfigurations']:
                for target in config['TestTargets']:
                    env = target.setdefault('EnvironmentVariables', {})
                    env['LOKALBOT_TEST_BUN'] = os.environ.get('LOKALBOT_TEST_BUN', '')
                    env['LOKALBOT_STUB_SCRIPT'] = str(Path('LokalBotTests/Fixtures/stub-openai.ts').resolve())
            run.write_bytes(plistlib.dumps(value))
    result_path = folder / f'{phase}.xcresult'
    command = ['bash', 'Scripts/test/ui-tests.sh', '--test-only', '--result', str(result_path)]
    for test in tests:
        command += ['--only', test]
    started = time.monotonic()
    with (folder / f'{phase}.log').open('w') as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            print(line, end='', flush=True)
            log.write(line)
        code = process.wait()
    report = dict(phase=phase, commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                  run=os.environ['GITHUB_RUN_ID'], attempt=os.environ['GITHUB_RUN_ATTEMPT'],
                  exit=code, seconds=round(time.monotonic() - started, 2), tests=[])
    if result_path.exists():
        tree = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                                                  '--path', str(result_path), '--compact']))
        report['tests'] = list(test_results(tree))
    # Even focused invocations must execute the requested tests. A typo must
    # never become a green zero-test run; focused checks remain separate from
    # the complete-suite gate and its 78-capture requirement.
    if code == 0 and (collections.Counter(t for t, status in report['tests']) != collections.Counter(tests)
                      or any(status != 'Passed' for t, status in report['tests'])):
        code = report['exit'] = 1
        print('::error::Selected UI tests were missing, failed or skipped')
    (folder / f'{phase}.json').write_text(json.dumps(report, indent=2))
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(summary, 'a') as stream:
            stream.write(f"| {phase} | {report['seconds']}s | exit {code} |\n")
    return code


def verify(root, phases=None):
    phases = phases or plan()
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    attempt = int(os.environ['GITHUB_RUN_ATTEMPT'])
    for phase, required in phases.items():
        paths = list(root.rglob(f'{phase}.json'))
        if len(paths) != 1:
            raise ValueError(f'Missing or duplicate report: {phase}')
        report = json.loads(paths[0].read_text())
        # A failed-jobs-only rerun keeps the reports of the runner that passed in
        # an earlier attempt of this run. Reports from another run or commit,
        # or a later attempt than this one, are stale.
        if ((report['commit'], report['run'], report['exit']) != (commit, os.environ['GITHUB_RUN_ID'], 0)
                or not 1 <= int(report['attempt']) <= attempt):
            raise ValueError(f'Failed or stale shard: {phase}')
        actual = [test for test, status in report['tests']]
        if collections.Counter(actual) != collections.Counter(required):
            raise ValueError(f'Test inventory mismatch: {phase}: expected {required}, got {actual}')
        if any(status != 'Passed' for test, status in report['tests']):
            raise ValueError(f'Failed or skipped required test: {phase}')
    expected = {f'{size}-{appearance}-{route}.png' for size in SIZES
                for appearance in ['light', 'dark'] for route in ROUTES}
    captures = list(root.rglob('captures/*.png'))
    if collections.Counter(p.name for p in captures) != collections.Counter(expected):
        raise ValueError(f'Missing, duplicate or unexpected matrix captures ({len(expected)} required)')
    for path in captures:
        data = path.read_bytes()
        size = tuple(map(int, path.name.split('-')[0].split('x')))
        if data[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', data[16:24]) != size:
            raise ValueError(f'Invalid capture dimensions: {path}')
    print(f'Complete UI coverage: {len(inventory())} unique tests and {len(expected)} correctly sized captures.')


if __name__ == '__main__':
    try:
        mode, *args = sys.argv[1:]
        if mode == 'plan':
            print(json.dumps(plan(), indent=2))
        elif mode == 'run':
            sys.exit(execute(*args))
        elif mode == 'gate':
            gate(*args)
        elif mode == 'verify':
            verify(Path(args[0]))
        elif mode == 'timings':
            Path('Scripts/ci/ui-durations.json').write_text(json.dumps(timings(args), indent=2) + '\n')
            durations = json.loads(Path('Scripts/ci/ui-durations.json').read_text())
            for phase in ['functional-1', 'functional-2']:
                tests = plan()[phase]
                print(f"{phase}: {len(tests)} tests, about {round(sum(durations.get(t, 30) for t in tests))} s")
        else:
            raise ValueError('Expected plan, run, gate, verify or timings')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
