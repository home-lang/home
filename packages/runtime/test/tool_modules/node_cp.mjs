import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { join, basename } from 'node:path';
const root = process.env.HOME_TOOL_COPY_FIXTURE;
if (!root) throw new Error('Real copy fixtures must be prepared by tool_copy_fixture.py');
const input = join(root, 'input');
const output = join(root, 'output');
const source = join(input, 'direct.bin');
let checks = 0;
const failures = [];
function assert(value, message) { if (!value) throw new Error(message); }
async function check(name, action) {
  checks++;
  try { await action(); } catch (error) { failures.push(name + ': ' + error.message); }
}
function code(error, expected) { assert(error && error.code === expected, 'expected ' + expected + ', got ' + (error && error.code)); }
const expected = await fsp.readFile(source);
async function contents(path) { assert((await fsp.readFile(path)).equals(expected), 'preserve every binary byte'); }
for (const sync of [false, true]) {
  const cp = sync ? (s, d, o) => fs.cpSync(s, d, o) : (s, d, o) => fsp.cp(s, d, o);
  const lane = sync ? 'sync' : 'promise';
  const dest = name => join(output, lane + '-' + name);
  await check(lane + ' file and missing parents', async () => {
    const path = dest('parents/deep/file');
    assert(await cp(source, path) === undefined, 'return undefined'); await contents(path);
    assert(((await fsp.stat(path)).mode & 0o777) === 0o750, 'copy actual file mode');
  });
  await check(lane + ' default overwrite', async () => {
    const path = dest('overwrite'); await fsp.writeFile(path, 'old'); await cp(source, path); await contents(path);
  });
  await check(lane + ' force false preserves existing file', async () => {
    const path = dest('no-force'); await fsp.writeFile(path, 'keep', { mode: 0o600 });
    assert(await cp(source, path, { force: false }) === undefined, 'skip returns undefined');
    assert(await fsp.readFile(path, 'utf8') === 'keep' && ((await fsp.stat(path)).mode & 0o777) === 0o600, 'do not overwrite data or permissions');
  });
  await check(lane + ' error on existing file', async () => {
    const path = dest('error-exists'); await fsp.writeFile(path, 'keep'); let error;
    try { await cp(source, path, { force: false, errorOnExist: true }); } catch (caught) { error = caught; }
    code(error, 'ERR_FS_CP_EEXIST'); assert(await fsp.readFile(path, 'utf8') === 'keep', 'preserve existing bytes');
  });
  await check(lane + ' force overrides errorOnExist', async () => {
    const path = dest('force'); await fsp.writeFile(path, 'old'); await cp(source, path, { force: true, errorOnExist: true }); await contents(path);
  });
  await check(lane + ' same file rejected', async () => {
    let error; try { await cp(source, source); } catch (caught) { error = caught; }
    code(error, 'ERR_FS_CP_EINVAL'); await contents(source);
  });
  await check(lane + ' hardlink identity rejected', async () => {
    let error; try { await cp(source, join(input, 'same-inode')); } catch (caught) { error = caught; }
    code(error, 'ERR_FS_CP_EINVAL'); await contents(source); await contents(join(input, 'same-inode'));
  });
  await check(lane + ' directory needs recursive', async () => {
    const path = dest('not-recursive'); let error;
    try { await cp(join(input, 'tree'), path); } catch (caught) { error = caught; }
    code(error, 'ERR_FS_EISDIR'); assert(!fs.existsSync(path), 'do not create rejected destination');
  });
  await check(lane + ' recursive tree', async () => {
    const path = dest('tree'); await cp(join(input, 'tree'), path, { recursive: true });
    assert(await fsp.readFile(join(path, 'deep', 'espaço-🦎'), 'utf8') === 'unicode data', 'copy nested UTF-8 names');
    assert((await fsp.stat(join(path, 'empty'))).isDirectory(), 'copy empty directory');
    assert(await fsp.readFile(join(path, '.hidden'), 'utf8') === 'hidden', 'copy dotfiles');
    assert(((await fsp.stat(join(path, 'deep', 'espaço-🦎'))).mode & 0o777) === 0o640, 'preserve nested file mode');
  });
  await check(lane + ' merge keeps directory mode and extra data', async () => {
    const path = dest('merge'); await fsp.mkdir(path, { mode: 0o700 }); await fsp.writeFile(join(path, 'extra'), 'keep');
    await cp(join(input, 'tree'), path, { recursive: true });
    assert(await fsp.readFile(join(path, 'extra'), 'utf8') === 'keep', 'merge without removing extra files');
    assert(((await fsp.stat(path)).mode & 0o777) === 0o700, 'preserve existing destination directory mode');
  });
  await check(lane + ' directory cannot replace file', async () => {
    const path = dest('dir-to-file'); await fsp.writeFile(path, 'keep'); let error;
    try { await cp(join(input, 'tree'), path, { recursive: true }); } catch (caught) { error = caught; }
    code(error, 'ERR_FS_CP_DIR_TO_NON_DIR'); assert(await fsp.readFile(path, 'utf8') === 'keep', 'preserve file');
  });
  await check(lane + ' file cannot replace directory', async () => {
    const path = dest('file-to-dir'); await fsp.mkdir(path); await fsp.writeFile(join(path, 'child'), 'keep'); let error;
    try { await cp(source, path); } catch (caught) { error = caught; }
    code(error, 'ERR_FS_CP_NON_DIR_TO_DIR'); assert(await fsp.readFile(join(path, 'child'), 'utf8') === 'keep', 'preserve directory contents');
  });
  await check(lane + ' missing source', async () => {
    const path = dest('missing'); let error;
    try { await cp(join(input, 'missing'), path); } catch (caught) { error = caught; }
    code(error, 'ENOENT'); assert(!fs.existsSync(path), 'no fabricated copy');
  });
  await check(lane + ' root filter false', async () => {
    const path = dest('filtered'); let calls = 0;
    assert(await cp(source, path, { filter(from, to) { calls++; assert(from === source && to === path, 'filter receives both paths'); return false; } }) === undefined, 'filtered result');
    assert(calls === 1 && !fs.existsSync(path), 'do not create filtered root');
  });
  await check(lane + ' excluded subtree is not visited', async () => {
    const path = dest('pruned'); const calls = [];
    await cp(join(input, 'tree'), path, { recursive: true, filter(from) { calls.push(from); return basename(from) !== 'omit'; } });
    assert(!fs.existsSync(join(path, 'omit')), 'excluded directory remains absent');
    assert(!calls.some(p => p.endsWith('/omit/child')), 'do not visit children of excluded directory');
    assert(await fsp.readFile(join(path, '.hidden'), 'utf8') === 'hidden', 'copy selected siblings');
  });
  await check(lane + ' filter exception identity', async () => {
    const sentinel = new Error('filter failed'); const path = dest('throw'); let error;
    try { await cp(source, path, { filter() { throw sentinel; } }); } catch (caught) { error = caught; }
    assert(error === sentinel && !fs.existsSync(path), 'preserve actual filter exception');
  });
  await check(lane + ' descendant destination rejected', async () => {
    const path = join(input, 'tree', lane + '-inside'); let error;
    try { await cp(join(input, 'tree'), path, { recursive: true }); } catch (caught) { error = caught; }
    code(error, 'ERR_FS_CP_EINVAL'); assert(!fs.existsSync(path), 'do not recurse into newly created destination');
  });
  await check(lane + ' symlink parent descendant rejected', async () => {
    const path = join(input, 'alias-to-tree', lane + '-inside-link'); let error;
    try { await cp(join(input, 'tree'), path, { recursive: true }); } catch (caught) { error = caught; }
    code(error, 'ERR_FS_CP_EINVAL'); assert(!fs.existsSync(path), 'check real parent identity before creating anything');
  });
  await check(lane + ' read-only directory copied after children', async () => {
    const path = dest('readonly'); await cp(join(input, 'readonly'), path, { recursive: true });
    assert(await fsp.readFile(join(path, 'file'), 'utf8') === 'read-only tree', 'copy actual contents');
    assert(((await fsp.stat(path)).mode & 0o777) === 0o555, 'restore source directory mode');
  });
  await check(lane + ' large file streamed', async () => {
    const path = dest('large.bin'); await cp(join(input, 'large.bin'), path);
    assert((await fsp.stat(path)).size === 9 * 1024 * 1024, 'copy complete large file; Python independently checks every byte');
  });
  await check(lane + ' root filter precedes same-file validation', async () => {
    assert(await cp(source, source, { filter: () => false }) === undefined, 'filtered same path is untouched'); await contents(source);
  });
}
await check('promised filter is awaited', async () => {
  const path = join(output, 'async-filter'); let calls = 0;
  await fsp.cp(join(input, 'tree'), path, { recursive: true, filter: async (from) => { await Promise.resolve(); calls++; return basename(from) !== 'omit'; } });
  assert(calls > 1 && !fs.existsSync(join(path, 'omit')) && fs.existsSync(join(path, '.hidden')), 'await every selected filter and prune excluded subtree');
});
await check('promised filter rejection identity', async () => {
  const sentinel = new Error('async filter'); let error;
  try { await fsp.cp(source, join(output, 'rejected'), { filter: async () => { throw sentinel; } }); } catch (caught) { error = caught; }
  assert(error === sentinel && !fs.existsSync(join(output, 'rejected')), 'preserve rejection without copying');
});
await check('sync refuses async filter', async () => {
  let error; try { fs.cpSync(source, join(output, 'sync-async-filter'), { filter: async () => true }); } catch (caught) { error = caught; }
  code(error, 'ERR_INVALID_RETURN_VALUE'); assert(!fs.existsSync(join(output, 'sync-async-filter')), 'do not execute copy after invalid sync filter');
});
await check('private filesystem identity does not leak through Stats', async () => {
  assert(!('identity' in await fsp.stat(source)) && !('identity' in fs.lstatSync(source)), 'retain public Stats surface');
});
await check('real synchronous chmod', async () => {
  const path = join(output, 'chmod-sync'); await fsp.writeFile(path, 'same bytes');
  assert(fs.chmodSync(path, 0o640) === undefined && ((await fsp.stat(path)).mode & 0o777) === 0o640, 'change actual mode');
});
await check('real promised octal chmod', async () => {
  const path = join(output, 'chmod-promise'); await fsp.writeFile(path, 'same bytes');
  assert(await fsp.chmod(path, '600') === undefined && ((await fsp.stat(path)).mode & 0o777) === 0o600, 'parse octal and change actual mode');
});
await check('chmod propagates missing path', async () => {
  let error; try { await fsp.chmod(join(output, 'no-chmod'), 0o600); } catch (caught) { error = caught; }
  code(error, 'ENOENT');
});
if (failures.length) throw new Error('NODE CP ' + checks + ' checks; failures: ' + failures.join('; '));
console.log('NODE CP ' + checks + ' CHECKS OK');
