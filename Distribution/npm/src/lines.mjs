import fs from 'node:fs';
import { pipeline } from 'node:stream/promises';
import zlib from 'node:zlib';

const CHUNK = 4 * 1024 * 1024;

export const MAX_LINE = 64 * 1024 * 1024;

export const canReadZstd = typeof zlib.createZstdDecompress === 'function';

export function isZstd(file) {
  return file.endsWith('.zst');
}

export function forEachLine(file, onLine, { chunkSize = CHUNK, maxLine = MAX_LINE } = {}) {
  const fd = fs.openSync(file, 'r');
  let total = 0;
  try {
    const chunk = Buffer.allocUnsafe(chunkSize);
    const splitter = lineSplitter(onLine, maxLine);
    for (;;) {
      const read = fs.readSync(fd, chunk, 0, chunkSize, null);
      if (read === 0) break;
      total += read;
      splitter.push(read === chunkSize ? chunk : chunk.subarray(0, read));
    }
    splitter.finish();
  } finally {
    fs.closeSync(fd);
  }
  return total;
}

export async function forEachLineAsync(file, onLine, { chunkSize = CHUNK, maxLine = MAX_LINE } = {}) {
  if (!isZstd(file)) return forEachLine(file, onLine, { chunkSize, maxLine });
  if (!canReadZstd) throw new Error('This Node.js cannot read zstd files.');
  let total = 0;
  const splitter = lineSplitter(onLine, maxLine);
  await pipeline(
    fs.createReadStream(file, { highWaterMark: chunkSize }),
    zlib.createZstdDecompress({ chunkSize }),
    async (source) => {
      for await (const chunk of source) {
        total += chunk.length;
        splitter.push(chunk);
      }
    },
  );
  splitter.finish();
  return total;
}

function lineSplitter(onLine, maxLine) {
  let carry = [];
  let carryLength = 0;
  let skipping = false;
  const emit = (line) => {
    let end = line.length;
    if (end > 0 && line[end - 1] === 13) end -= 1;
    if (end > 0) onLine(end === line.length ? line : line.subarray(0, end));
  };
  return {
    push(view) {
      let start = 0;
      while (start < view.length) {
        const end = view.indexOf(10, start);
        if (end === -1) {
          if (!skipping) {
            const piece = Buffer.from(view.subarray(start));
            carry.push(piece);
            carryLength += piece.length;
            if (carryLength > maxLine) {
              carry = [];
              carryLength = 0;
              skipping = true;
            }
          }
          break;
        }
        if (skipping) {
          skipping = false;
        } else if (carryLength > 0) {
          carry.push(view.subarray(start, end));
          const line = Buffer.concat(carry, carryLength + end - start);
          carry = [];
          carryLength = 0;
          emit(line);
        } else if (end > start) {
          emit(view.subarray(start, end));
        }
        start = end + 1;
      }
    },
    finish() {
      if (!skipping && carryLength > 0) emit(Buffer.concat(carry, carryLength));
      carry = [];
      carryLength = 0;
    },
  };
}
