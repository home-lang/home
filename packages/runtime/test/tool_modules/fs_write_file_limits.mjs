import { mkdir, rm, writeFile } from 'node:fs/promises';
const base = process.cwd() + '/.zig-cache/write-file-limits-' + process.pid;
await mkdir(base, { recursive: true });
try {
  for (const options of [{ flag: 'rs' }, { flag: 'as' }, { mode: 0o10000 }, { encoding: 'latin1' }, { flush: true }, { signal: {} }]) {
    let refused = false;
    try { await writeFile(base + '/unsupported', 'actual', options); } catch (error) { refused = error.code === 'ERR_HOME_UNSUPPORTED'; }
    if (!refused || Home.fileExists(base + '/unsupported')) throw new Error('unsupported option was not refused before writing');
  }
  let iterableRefused = false;
  try { await writeFile(base + '/iterable', []); } catch (error) { iterableRefused = error.code === 'ERR_HOME_UNSUPPORTED'; }
  if (!iterableRefused || Home.fileExists(base + '/iterable')) throw new Error('unsupported iterable was not refused before writing');
  console.log('OK unsupported file-write options are refused before writing');
} finally { await rm(base, { recursive: true, force: true }); }
