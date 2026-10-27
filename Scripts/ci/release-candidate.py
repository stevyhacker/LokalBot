#!/usr/bin/env python3
"""Fail-closed release gates and trusted, exact-commit archive preparation reuse."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

GATES = {
    'build.yml': ['xcodebuild (macOS)', 'xcodebuild test (macOS)'],
    'ui-tests.yml': ['XCUITest (macOS)'],
    'lint.yml': ['SwiftLint'],
    'xcodegen.yml': ['project.yml generates cleanly'],
}
# UI Tests no longer runs on every master push. prepare-release.sh dispatches
# it for the candidate, and that run binds itself to the exact SHA it was
# asked to test before any job runs. Only a full run reports `XCUITest
# (macOS)`; filtered and legacy-comparison dispatches use another name.
GATE_EVENTS = {'ui-tests.yml': ('push', 'workflow_dispatch')}
# Without an exact-commit UI run, the merged pull request's run counts when it
# tested this exact tree (merged_pull_request_ui). `UI build (macOS)` runs only
# when the suite does, so a draft or UI-irrelevant pass doesn't count.
PULL_REQUEST_UI_JOBS = ['UI build (macOS)']


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def api(path):
    return json.loads(command('gh', 'api', f"repos/{os.environ['GITHUB_REPOSITORY']}/{path}"))


def checkout_identity():
    if command('git', 'status', '--porcelain', '--untracked-files=no'):
        raise ValueError('Release artifact provenance requires clean tracked source inputs')
    info = plistlib.loads(Path('LokalBot/Info.plist').read_bytes())
    lock = Path('LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
    return dict(commit=command('git', 'rev-parse', 'HEAD'), tree=command('git', 'rev-parse', 'HEAD^{tree}'),
                xcode=command('xcodebuild', '-version'), sdk=command('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
                architecture=command('uname', '-m'),
                version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                lock=hashlib.sha256(lock.read_bytes()).hexdigest(), repository=os.environ['GITHUB_REPOSITORY'])


def trusted_tip():
    sha = command('git', 'rev-parse', 'HEAD')
    if api('git/ref/heads/master')['object']['sha'] != sha:
        raise ValueError('Release candidate is not the current trusted master commit')
    return sha


def successful_gate(runs, jobs, sha, required, events=('push',), branch='master'):
    # The newest qualifying run on this exact SHA is authoritative. An older
    # successful attempt cannot hide a running or failed rerun.
    candidates = [run for run in runs if run['head_sha'] == sha and run['head_branch'] == branch
                  and run['event'] in events]
    if not candidates:
        raise ValueError(f'No trusted {branch} validation for this exact commit')
    run = max(candidates, key=lambda item: (item['run_number'], item.get('run_attempt', 1)))
    if run['status'] != 'completed' or run['conclusion'] != 'success':
        raise ValueError('Latest exact-commit validation is not successful')
    actual = jobs(run['id'])
    for name in required:
        matches = [job for job in actual if job['name'] == name]
        if len(matches) != 1 or matches[0]['conclusion'] != 'success':
            raise ValueError(f'Missing or unsuccessful release gate: {name}')
    return run['id']


def jobs_of(run):
    return api(f'actions/runs/{run}/jobs?filter=latest&per_page=100')['jobs']


def is_ancestor(older, newer):
    return subprocess.run(['git', 'merge-base', '--is-ancestor', older, newer]).returncode == 0


def merged_pull_request_ui(sha):
    """The run id of the full UI run that tested the candidate's exact tree in
    the pull request it merges, or a ValueError saying why there is none.

    GitHub tests a pull request's head merged into its base as the base was
    then. When the head already contains master as it was just before the
    merge, it contains every earlier master too (master only moves forward),
    so that test merge is the head's own tree. The candidate merge then has
    the same tree."""
    parents = command('git', 'rev-list', '--parents', '-n', '1', sha).split()[1:]
    if len(parents) != 2:
        raise ValueError('The candidate is not a pull request merge')
    base, head = parents
    repository = os.environ['GITHUB_REPOSITORY'].lower()
    pulls = [pull for pull in api(f'commits/{sha}/pulls') if pull.get('merge_commit_sha') == sha]
    if (len(pulls) != 1 or not pulls[0].get('merged_at') or pulls[0]['base']['ref'] != 'master'
            or pulls[0]['head']['sha'] != head
            or ((pulls[0]['head'].get('repo') or {}).get('full_name') or '').lower() != repository):
        raise ValueError('The candidate is not the merge of a pull request from this repository into master')
    if command('git', 'rev-parse', f'{sha}^{{tree}}') != command('git', 'rev-parse', f'{head}^{{tree}}'):
        raise ValueError('The candidate differs from the pull request head it merges')
    if not is_ancestor(base, head):
        raise ValueError('The pull request did not contain master when it merged')
    runs = [run for run in api(f'actions/workflows/ui-tests.yml/runs?head_sha={head}&event=pull_request&per_page=100')['workflow_runs']
            if ((run.get('head_repository') or {}).get('full_name') or '').lower() == repository]
    return successful_gate(runs, jobs_of, head, GATES['ui-tests.yml'] + PULL_REQUEST_UI_JOBS,
                           ('pull_request',), branch=pulls[0]['head']['ref'])


def gates():
    sha = trusted_tip()
    for workflow, required in GATES.items():
        events = GATE_EVENTS.get(workflow, ('push',))
        runs = [run for event in events
                for run in api(f'actions/workflows/{workflow}/runs?head_sha={sha}&event={event}&per_page=100')['workflow_runs']]
        # An exact-commit UI run, when there is one, decides on its own.
        if workflow == 'ui-tests.yml' and not any(run['head_sha'] == sha and run['head_branch'] == 'master'
                                                  for run in runs):
            run_id = merged_pull_request_ui(sha)
            print(f"Verified {workflow} run {run_id} of the merged pull request, which tested this exact tree: "
                  f"{', '.join(required + PULL_REQUEST_UI_JOBS)}")
            continue
        run_id = successful_gate(runs, jobs_of, sha, required, events)
        print(f"Verified {workflow} run {run_id}: {', '.join(required)}")


def ui_covered():
    """For prepare-release.sh: succeed when the merged pull request's UI run
    already covers the candidate, so no exact-commit run is needed."""
    run_id = merged_pull_request_ui(trusted_tip())
    print(f'UI Tests run {run_id} of the merged pull request tested this exact tree.')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate_prepared(saved, current, run_id, archive, attempt):
    if saved['identity'] != current or saved['run'] != str(run_id) or saved['attempt'] != str(attempt) or saved['sha256'] != digest(archive):
        raise ValueError('Prepared app commit, metadata, toolchain, run or digest mismatch')


def prepare():
    trusted_tip()
    if os.environ['GITHUB_EVENT_NAME'] != 'workflow_dispatch' or os.environ['GITHUB_REF'] != 'refs/heads/master':
        raise ValueError('Archive preparation requires an explicit dispatch on master')
    subprocess.run(['python3', 'Scripts/release-preflight.py', '--candidate', '--version', os.environ['CANDIDATE_VERSION']], check=True)


def verify_app():
    current = checkout_identity()
    app = plistlib.loads(Path('build/export/LokalBot.app/Contents/Info.plist').read_bytes())
    if (app['CFBundleShortVersionString'], app['CFBundleVersion']) != (current['version'], current['build']):
        raise ValueError('Exported app version/build differs from candidate metadata')


def pack():
    archive = Path('build/prepared/app.zip')
    archive.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', '-c', '-k', '--keepParent', 'build/export/LokalBot.app', str(archive)], check=True)
    saved = dict(identity=checkout_identity(), run=os.environ['GITHUB_RUN_ID'],
                 attempt=os.environ['GITHUB_RUN_ATTEMPT'], sha256=digest(archive),
                 runner_image=dict(os=os.environ.get('ImageOS', ''), version=os.environ.get('ImageVersion', '')))
    archive.with_suffix('.json').write_text(json.dumps(saved, indent=2))


def restore():
    identity = checkout_identity()
    sha = identity['commit']
    runs = api(f'actions/workflows/release.yml/runs?head_sha={sha}&event=workflow_dispatch&per_page=100')['workflow_runs']
    for run in sorted(runs, key=lambda item: item['run_number'], reverse=True):
        if (run['head_sha'], run['head_branch'], run['event'], run['status'], run['conclusion']) != (
                sha, 'master', 'workflow_dispatch', 'completed', 'success'):
            continue
        name = 'prepared-app-' + sha
        artifacts = api(f"actions/runs/{run['id']}/artifacts?per_page=100")['artifacts']
        matches = [a for a in artifacts if a['name'] == name and not a['expired']]
        if not matches:
            continue
        if len(matches) != 1:
            raise ValueError('Ambiguous prepared archive')
        subprocess.run(['gh', 'run', 'download', str(run['id']), '--repo', os.environ['GITHUB_REPOSITORY'],
                        '--name', name, '--dir', 'build/prepared'], check=True)
        archive = Path('build/prepared/app.zip')
        validate_prepared(json.loads(archive.with_suffix('.json').read_text()), identity, run['id'], archive, run['run_attempt'])
        subprocess.run(['ditto', '-x', '-k', str(archive), 'build/export'], check=True)
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write('reused=true\n')
        print(f"Reusing verified prepared app from run {run['id']}")
        return
    print('No trusted exact-commit prepared app; use the cold archive path.')


if __name__ == '__main__':
    try:
        {'gates': gates, 'prepare': prepare, 'pack': pack, 'restore': restore, 'verify-app': verify_app,
         'ui-covered': ui_covered}[sys.argv[1]]()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
