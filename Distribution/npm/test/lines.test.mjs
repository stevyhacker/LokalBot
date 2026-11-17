import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import zlib from 'node:zlib';

import { canReadZstd, forEachLine, forEachLineAsync } from '../src/lines.mjs';
import { temporaryFolder } from './helpers.mjs';

function read(file, options) {
  const lines = [];
  const bytes = forEachLine(file, (line) => lines.push(line.toString('utf8')), options);
  return { lines, bytes };
}

test('lines that span read chunks arrive whole', (t) => {
  const file = path.join(temporaryFolder(t), 'log.jsonl');
  const content = ['{"a":1}', '{"b":"a line longer than one chunk of sixteen bytes"}', '{"c":3}'];
  fs.writeFileSync(file, `${content.join('\n')}\n`);
  for (const chunkSize of [4, 16, 17, 1024]) {
    assert.deepEqual(read(file, { chunkSize }).lines, content, `chunk size ${chunkSize}`);
  }
  assert.equal(read(file, { chunkSize: 16 }).bytes, fs.statSync(file).size);
});

test('a last line without a newline, blank lines and CRLF endings are handled', (t) => {
  const file = path.join(temporaryFolder(t), 'log.jsonl');
  fs.writeFileSync(file, '{"a":1}\r\n\n\r\n{"b":2}');
  assert.deepEqual(read(file, { chunkSize: 8 }).lines, ['{"a":1}', '{"b":2}']);
});

test('a line over the limit is skipped and the lines after it are kept', (t) => {
  const file = path.join(temporaryFolder(t), 'log.jsonl');
  fs.writeFileSync(file, `{"a":1}\n{"big":"${'x'.repeat(500)}"}\n{"c":3}\n`);
  assert.deepEqual(read(file, { chunkSize: 32, maxLine: 100 }).lines, ['{"a":1}', '{"c":3}']);
});

test('a zstd file is read line by line, across chunks, with the same lines as the plain one', { skip: !canReadZstd && 'this Node.js has no zstd' }, async (t) => {
  const folder = temporaryFolder(t);
  const text = ['{"a":1}', 'x'.repeat(5000), '', '{"b":2}\r', 'last without a newline'].join('\n');
  const plain = path.join(folder, 'rollout.jsonl');
  fs.writeFileSync(plain, text);
  const packed = `${plain}.zst`;
  fs.writeFileSync(packed, zlib.zstdCompressSync(Buffer.from(text)));

  const lines = [];
  const bytes = await forEachLineAsync(packed, (line) => lines.push(line.toString('utf8')), { chunkSize: 1024 });
  assert.equal(bytes, Buffer.byteLength(text));
  assert.deepEqual(lines, read(plain, { chunkSize: 1024 }).lines);
  assert.deepEqual(lines, ['{"a":1}', 'x'.repeat(5000), '{"b":2}', 'last without a newline']);
});

test('throwing from the callback stops reading a zstd file', { skip: !canReadZstd && 'this Node.js has no zstd' }, async (t) => {
  const folder = temporaryFolder(t);
  const packed = path.join(folder, 'rollout.jsonl.zst');
  fs.writeFileSync(packed, zlib.zstdCompressSync(Buffer.from('first\nsecond\nthird\n')));
  const stop = new Error('stop');
  const seen = [];
  await assert.rejects(forEachLineAsync(packed, (line) => {
    seen.push(line.toString('utf8'));
    throw stop;
  }), (error) => error === stop);
  assert.deepEqual(seen, ['first']);
});
