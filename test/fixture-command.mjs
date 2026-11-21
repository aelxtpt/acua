import fs from 'node:fs';
import { randomUUID } from 'node:crypto';

// Fixtures poll and unlink their command file. Publishing an empty file before
// writing lets the reader consume it too early. Rename only complete contents.
export function publishFixtureCommand(file, contents) {
  const staged = `${file}.${randomUUID()}.pending`;
  try {
    fs.writeFileSync(staged, contents, { flag: 'wx', mode: 0o600 });
    fs.renameSync(staged, file);
  } finally {
    try { fs.unlinkSync(staged); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
