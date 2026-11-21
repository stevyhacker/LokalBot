import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

process.env.TZ = 'UTC';

export const YEAR = new Date().getFullYear();

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
export function id(prefix = 'record') {
  nextId += 1;
  return `${prefix}-${String(nextId).padStart(6, '0')}`;
}
