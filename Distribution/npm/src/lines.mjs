// Streams a JSON Lines transcript as raw bytes, one line at a time, so a
// multi-gigabyte log never has to fit in memory. Tool output dominates these
// files: a single line can hold a multi-megabyte screenshot.

import fs from 'node:fs';

const CHUNK = 4 * 1024 * 1024;

/** Lines longer than this are skipped: nothing a reader counts is that large. */
export const MAX_LINE = 64 * 1024 * 1024;

/**
 * Calls `onLine(bytes)` for every non-empty line of `file`. The buffer is
 * only valid during the call. Returns the number of bytes read.
 */
export function forEachLine(file, onLine, { chunkSize = CHUNK, maxLine = MAX_LINE } = {}) {
  const fd = fs.openSync(file, 'r');
  let total = 0;
  try {
    const chunk = Buffer.allocUnsafe(chunkSize);
    let carry = [];
    let carryLength = 0;
    let skipping = false;
    const emit = (line) => {
      let end = line.length;
      if (end > 0 && line[end - 1] === 13) end -= 1;
      if (end > 0) onLine(end === line.length ? line : line.subarray(0, end));
    };
    for (;;) {
      const read = fs.readSync(fd, chunk, 0, chunkSize, null);
      if (read === 0) break;
      total += read;
      const view = read === chunkSize ? chunk : chunk.subarray(0, read);
      let start = 0;
      while (start < view.length) {
        const end = view.indexOf(10, start);
        if (end === -1) {
          if (!skipping) {
            // The chunk buffer is reused, so a line that continues is copied.
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
    }
    if (!skipping && carryLength > 0) emit(Buffer.concat(carry, carryLength));
  } finally {
    fs.closeSync(fd);
  }
  return total;
}
