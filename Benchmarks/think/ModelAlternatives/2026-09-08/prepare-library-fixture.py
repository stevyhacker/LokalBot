"""Create a temporary library snapshot for the native embedding integration test.

Queries are supplied separately so private meeting content never becomes a
repository fixture. The CLI enforces the user's meeting-library access grant.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--work', type=Path, required=True)
parser.add_argument('--queries', type=Path, required=True)
parser.add_argument('--model', type=Path, required=True)
parser.add_argument('--cli', default='/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli')
args = parser.parse_args()
work = args.work.resolve()
allowed = [Path('/private/tmp').resolve(), Path(tempfile.gettempdir()).resolve()]
if not any(parent in work.parents for parent in allowed):
    raise SystemExit('Use a new directory beneath a temporary directory.')
library = work/'staged-library'
if library.exists():
    raise SystemExit('Snapshot already exists. Choose a new --work directory.')
queries = json.loads(args.queries.read_text())
meetings = json.loads(subprocess.check_output([args.cli, 'list', '--limit', '200']))
if not isinstance(meetings, list):
    raise SystemExit('The CLI did not grant/list meeting-library access.')
selected = [m for m in meetings if m['has_transcript']]
ids = {m['id'] for m in selected}
if not queries or any(not set(q['relevant_meetings']).issubset(ids) for q in queries):
    raise SystemExit('Queries must refer to transcribed meetings in this snapshot.')
exports = work/'library'
exports.mkdir(parents=True)
library.mkdir()
for meeting in selected:
    raw = subprocess.check_output([args.cli, 'get', meeting['id'], '--format', 'json'])
    exported = json.loads(raw)
    if not isinstance(exported, dict) or 'folder' not in exported:
        raise SystemExit('The CLI did not return authorized meeting data.')
    (exports/(meeting['id']+'.json')).write_bytes(raw)
    source = Path(exported['folder'])
    meta = json.loads((source/'meta.json').read_text())
    destination = (library/meta['relativePath']).resolve()
    if library not in destination.parents:
        raise SystemExit('Invalid meeting-relative path.')
    destination.mkdir(parents=True)
    for name in ['meta.json', 'transcript.json', 'summary.md']:
        if (source/name).exists():
            shutil.copy2(source/name, destination/name)
model_directory = library/'models'
model_directory.mkdir()
shutil.copy2(args.model, model_directory/'harrier-oss-v1-0.6b.Q8_0.gguf')
fixture = {'libraryRoot': str(library), 'meetingCount': len(selected), 'queries': queries}
(work/'native-embedding-fixture.json').write_text(json.dumps(fixture, indent=2, ensure_ascii=False))
print('Prepared', len(selected), 'transcribed meetings in', library)
