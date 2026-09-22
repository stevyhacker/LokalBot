#!/usr/bin/env python3
"""Plan disjoint XCTest shards and verify executed tests plus every matrix PNG."""
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
SMOKE = [
    'RedesignUITests/testHighContrastKeepsActionsAccessible',
    'MainWindowUITests/testMeetingWaveformExposesSliderAndSupportsKeyboardSeeking',
    'AgentModeUITests',
    'RedesignUITests/testAgentApprovalDescribesEffectAndDenialAndStopReachTheController',
    'RedesignUITests/testFourHundredActionsStaySearchableAndCompletionCanBeUndone',
    'MainWindowUITests/testMultiMeetingThreadCompletionRequiresConfirmation',
    'MainWindowUITests/testActionThreadSourceCanBeSeparatedAndRestored',
]
SIZES = ['1000x700', '1180x740', '1440x900']
ROUTES = ['today', 'actions', 'meeting', 'transcript', 'review', 'timeline', 'search', 'ask',
          'settings', 'models', 'dictation', 'autocomplete', 'agent']


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
    remainder = set(tests) - set(smoke) - {REDUCED, VISUAL}
    timings = json.loads(Path('Scripts/ci/ui-durations.json').read_text())
    shards = [[], []]
    totals = [0, 0]
    for test in sorted(remainder, key=lambda test: (-timings.get(test, 30), test)):
        index = totals.index(min(totals))
        shards[index].append(test)
        totals[index] += timings.get(test, 30)
    return dict(smoke=smoke, **{'reduced-motion': [REDUCED],
                               'functional-1': shards[0], 'functional-2': shards[1]},
                **{f'visual-{size}': [VISUAL] for size in SIZES})


def test_results(node):
    if isinstance(node, dict):
        if node.get('nodeType') == 'Test Case':
            yield node['nodeIdentifier'].removesuffix('()'), node['result']
        for child in node.get('children', node.get('testNodes', [])):
            yield from test_results(child)


def execute(phase, selected=None):
    if os.environ.get('CI') != 'true':
        raise ValueError('Shard execution is hosted-only')
    phases = plan()
    tests = [selected] if phase == 'single' else phases[phase]
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
    result_path = folder / f'{phase}.xcresult'
    command = ['bash', 'Scripts/ui-tests.sh', '--test-only', '--result', str(result_path)]
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
    (folder / f'{phase}.json').write_text(json.dumps(report, indent=2))
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(summary, 'a') as stream:
            stream.write(f"| {phase} | {report['seconds']}s | exit {code} |\n")
    return code


def verify(root, phases=None):
    phases = phases or plan()
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    for phase, required in phases.items():
        paths = list(root.rglob(f'{phase}.json'))
        if len(paths) != 1:
            raise ValueError(f'Missing or duplicate report: {phase}')
        report = json.loads(paths[0].read_text())
        if (report['commit'], report['run'], report['attempt'], report['exit']) != (
                commit, os.environ['GITHUB_RUN_ID'], os.environ['GITHUB_RUN_ATTEMPT'], 0):
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
        elif mode == 'verify':
            verify(Path(args[0]))
        else:
            raise ValueError('Expected plan, run or verify')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
