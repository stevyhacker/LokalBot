// Shared by the tests. Log files are written into a temporary folder; the
// tests never read the real ~/.claude or ~/.codex.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// A year runs from midnight to midnight where the person is. The fixtures
// are written in UTC, so the tests run there too.
process.env.TZ = 'UTC';

// Files are chosen by when they were written, so fixtures live in this year.
export const YEAR = new Date().getFullYear();

/** `at(3, 14, 9, 30)` is 09:30:00 UTC on 14 March of the test year. */
export function at(month, day, hour = 12, minute = 0, second = 0) {
  return new Date(Date.UTC(YEAR, month - 1, day, hour, minute, second)).toISOString();
}

export function temporaryFolder(t) {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-wrapped-test-'));
  t.after(() => fs.rmSync(folder, { recursive: true, force: true }));
  return folder;
}

export function writeLines(file, records) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, records.map((record) => (typeof record === 'string' ? record : JSON.stringify(record))).join('\n') + '\n');
  return file;
}

let nextId = 0;
/** A record id that is unique within a test run. */
export function id(prefix = 'record') {
  nextId += 1;
  return `${prefix}-${String(nextId).padStart(6, '0')}`;
}
