import fs from 'node:fs';
import { promisify } from 'node:util';
import { join } from 'node:path';
const root = process.argv[2], text = join(root, 'text-☃.txt'), binary = join(root, 'binary.dat');
const missing = join(root, 'does-not-exist'), failures = [], passed = [];
const read = promisify(fs.readFile), list = promisify(fs.readdir);
async function group(name, fn) { try { if (!await fn()) throw new Error('predicate failed'); passed.push(name); } catch (e) { failures.push({ name, error: String(e) }); } }
function callbackRead(method, path, options) {
  return new Promise((resolve, reject) => {
    let returned = false, count = 0;
    const callback = function(error, value) {
      count++;
      if (!returned || count !== 1 || arguments.length !== (error ? 1 : 2)) { reject(new Error('callback timing/count/arity mismatch')); return; }
      resolve({ error, value });
    };
    const result = options === undefined ? method(path, callback) : method(path, options, callback);
    returned = true;
    if (result !== undefined) reject(new Error('callback read returned an invented handle'));
  });
}
await group('raw-buffer-and-deferred-callback', async () => {
  const r = await callbackRead(fs.readFile, binary);
  return r.error === null && Buffer.isBuffer(r.value) && r.value.length === 65536 && r.value[0] === 11 && r.value[65535] === ((65535 * 37 + 11) & 255);
});
await group('utf8-string', async () => { const r = await callbackRead(fs.readFile, text, 'utf8'); return r.error === null && r.value === 'real UTF8 ☃\0line\n'; });
await group('explicit-utf8-options', async () => (await read(text, { encoding: 'utf-8', flag: 'r' })) === 'real UTF8 ☃\0line\n');
await group('null-options-buffer', async () => Buffer.isBuffer(await read(text, null)));
await group('promisified-binary', async () => (await read(binary)).length === 65536);
await group('malformed-utf8-keeps-nul', async () => (await read(join(root, 'malformed.dat'), 'utf8')) === '\ufffd\0\ufffd');
await group('read-missing-async-error', async () => { const r = await callbackRead(fs.readFile, missing); return r.error.code === 'ENOENT' && r.value === undefined; });
await group('read-directory-error', async () => { const r = await callbackRead(fs.readFile, root); return r.error.code === 'EISDIR'; });
await group('promisified-read-rejection', async () => { try { await read(missing); return false; } catch (e) { return e.code === 'ENOENT'; } });
const names = ['binary.dat', 'dangling', 'dir', 'link', 'malformed.dat', 'text-☃.txt'];
await group('real-directory-names', async () => { const r = await callbackRead(fs.readdir, root); return r.error === null && r.value.sort().join('|') === names.join('|'); });
await group('real-dirent-brands', async () => {
  const entries = await list(root, { withFileTypes: true }); const byName = Object.fromEntries(entries.map(e => [e.name, e]));
  return byName.dir.isDirectory() && !byName.dir.isFile() && byName['binary.dat'].isFile() && byName.link.isSymbolicLink() && byName.dangling.isSymbolicLink() && entries.every(e => e.parentPath === root);
});
await group('directory-missing-async-error', async () => { const r = await callbackRead(fs.readdir, missing); return r.error.code === 'ENOENT'; });
await group('directory-on-file-error', async () => { const r = await callbackRead(fs.readdir, text); return r.error.code === 'ENOTDIR'; });
await group('promisified-directory-rejection', async () => { try { await list(missing); return false; } catch (e) { return e.code === 'ENOENT'; } });
await group('callback-validation-is-synchronous', async () => {
  for (const method of [fs.readFile, fs.readdir]) for (const callback of [undefined, null, 7, {}]) {
    let threw = false;
    try { method(missing, 'utf8', callback); } catch (e) { threw = e instanceof TypeError && e.code === 'ERR_INVALID_ARG_TYPE'; }
    if (!threw) return false;
  }
  return true;
});
await group('nul-path-validation-is-synchronous', async () => {
  for (const method of [fs.readFile, fs.readdir]) {
    let called = false, threw = false;
    try { method('bad\0path', () => { called = true; }); } catch (e) { threw = e instanceof TypeError && e.code === 'ERR_INVALID_ARG_VALUE'; }
    if (!threw || called) return false;
  }
  return true;
});
await group('read-options-snapshot', async () => { const options = { encoding: 'utf8' }; const result = read(text, options); options.encoding = null; return await result === 'real UTF8 ☃\0line\n'; });
await group('directory-options-snapshot', async () => { const options = { withFileTypes: true }; const result = list(root, options); options.withFileTypes = false; return (await result).every(e => typeof e.isFile === 'function'); });
await group('option-getter-data', async () => {
  let enc = 0, flag = 0; const options = { get encoding() { enc++; return 'utf8'; }, get flag() { flag++; return 'r'; } };
  // Node observes encoding three times; Bun snapshots once. Assert actual
  // data here, and pin Home's once-only snapshot in its separate profile.
  return await read(text, options) === 'real UTF8 ☃\0line\n' && enc > 0 && flag > 0;
});
await group('independent-of-public-sync-methods', async () => {
  const originals = [fs.readFileSync, fs.readdirSync];
  try {
    fs.readFileSync = fs.readdirSync = () => { throw new Error('public sync method must not supply data'); };
    return await read(text, 'utf8') === 'real UTF8 ☃\0line\n' && (await list(root)).includes('binary.dat');
  } finally { [fs.readFileSync, fs.readdirSync] = originals; }
});
await group('nested-callback-read', async () => {
  const r = await new Promise((resolve, reject) => fs.readFile(text, 'utf8', (error, value) => {
    if (error) { reject(error); return; }
    fs.readdir(root, (nextError, entries) => nextError ? reject(nextError) : resolve(value.startsWith('real UTF8') && entries.includes('binary.dat')));
  })); return r;
});
const physical = await read(binary);
console.log('FS CALLBACK READ RESULTS ' + JSON.stringify({ groups: passed.length + failures.length, passed: passed.length, failures }));
console.log('FS CALLBACK PHYSICAL ' + JSON.stringify({ bytes: physical.length, base64: physical.toString('base64') }));
if (failures.length) throw new Error('Actual callback filesystem contract failed');
console.log('FS CALLBACK READ ' + passed.length + ' GROUPS OK');
