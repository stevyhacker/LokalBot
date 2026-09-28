#!/usr/bin/env python3
"""Snapshot one Actions attempt without conflating queue time and runner time."""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import subprocess


def api(repo, path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{repo}/{path}'], text=True))


def epoch(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp() if value else None


def elapsed(start, end):
    a, b = epoch(start), epoch(end)
    return max(0, b - a) if a is not None and b is not None else None


def phase(name):
    lower = name.lower()
    if 'compiler' in lower and ('cache' in lower or 'evidence' in lower):
        return 'compiler cache / evidence'
    if 'cache' in lower:
        return 'dependency cache'
    if 'fetch llama' in lower:
        return 'vendor preparation'
    if name in ['Build UI test targets', 'Build app and unit-test targets']:
        return 'compilation'
    if 'package' in lower or 'restore compiled' in lower:
        return 'product packaging / restore'
    if any(word in lower for word in ['artifact', 'save shard', 'save smoke', 'save build', 'save phase', 'save unit']):
        return 'artifact transfer'
    if any(word in lower for word in ['critical interactions', 'reduce motion', 'run shard', 'single test',
                                      'run unit tests', 'audio recovery']):
        return 'tests'
    return 'setup / other'


def summarize(run, jobs):
    start = run['run_started_at']
    finished = {job['name']: job['completed_at'] for job in jobs if job.get('completed_at')}
    build = 'UI build (macOS)' if any(job['name'] == 'UI build (macOS)' for job in jobs) else 'UI build and critical tests'
    rows = []
    for job in jobs:
        eligible = start
        name = job['name']
        if name.startswith('UI ') and name != build:
            eligible = finished.get(build, start)
        elif name == 'xcodebuild test (macOS)':
            eligible = finished.get('xcodebuild (macOS)', start)
        elif name in ['XCUITest (macOS)', 'UI focused / comparison (macOS)']:
            eligible = max(finished.values(), default=start)
            # The gate's own completion cannot be a dependency.
            eligible = max((j['completed_at'] for j in jobs if j['id'] != job['id'] and j.get('completed_at')), default=start)
        steps = [dict(name=s['name'], result=s.get('conclusion'),
                      seconds=elapsed(s.get('started_at'), s.get('completed_at')), phase=phase(s['name']))
                 for s in job.get('steps', [])]
        seconds = elapsed(job.get('started_at'), job.get('completed_at'))
        macos = any('macos' in label.lower() for label in job.get('labels', []))
        rows.append(dict(id=job['id'], name=name, result=job.get('conclusion'), macos=macos,
                         started_at=job.get('started_at'), completed_at=job.get('completed_at'),
                         queue_seconds=elapsed(eligible, job.get('started_at')), seconds=seconds, steps=steps))
    totals = {}
    for row in rows:
        for step in row['steps']:
            totals[step['phase']] = totals.get(step['phase'], 0) + (step['seconds'] or 0)
    macos = [row for row in rows if row['macos'] and row['seconds'] is not None]
    critical = next((row for row in rows if row['name'] == 'UI build and critical tests'), None)
    return dict(run=run['id'], attempt=run['run_attempt'], workflow=run['name'], sha=run['head_sha'],
                url=run['html_url'] + f"/attempts/{run['run_attempt']}", event=run['event'],
                result=run['conclusion'], status=run['status'], started_at=start,
                wall_seconds=elapsed(start, max(finished.values())) if finished else None,
                build_and_critical_seconds=elapsed(start, critical['completed_at']) if critical else None,
                macos_runner_minutes=round(sum(row['seconds'] for row in macos) / 60, 2),
                macos_rounded_job_minutes=sum(math.ceil(row['seconds'] / 60) for row in macos),
                phase_seconds=totals, jobs=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=int)
    parser.add_argument('--attempt', type=int)
    parser.add_argument('--repo', default='stevyhacker/LokalBot')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    base = f'actions/runs/{args.run}'
    run = api(args.repo, base + (f'/attempts/{args.attempt}' if args.attempt else ''))
    jobs = []
    for page in range(1, 100):
        batch = api(args.repo, base + f"/attempts/{run['run_attempt']}/jobs?per_page=100&page={page}")['jobs']
        jobs += batch
        if len(batch) < 100:
            break
    report = summarize(run, jobs)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'jobs'}, indent=2))


if __name__ == '__main__':
    main()
