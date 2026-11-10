import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const base = join(tmpdir(), 'home-sync-fs-' + randomUUID());
await fsp.mkdir(base);
const failures = [];
let operations = 0;
function assert(value, message) { if (!value) throw new Error(message); }
async function check(name, run) {
  operations++;
  try { await run(); } catch (error) { failures.push(name + ': ' + error.message); }
}
function expected(error, code, path) { assert(error && error.code === code && error.path === path, 'expected ' + code + ' and original path'); }
try {
  for (const sync of [false, true]) {
    const mkdir = sync ? (p, o) => fs.mkdirSync(p, o) : (p, o) => fsp.mkdir(p, o);
    const rm = sync ? (p, o) => fs.rmSync(p, o) : (p, o) => fsp.rm(p, o);
    const lane = sync ? 'sync ' : 'promise ';
    await check(lane + 'mkdir private unicode', async () => {
      const path = join(base, 'espaço-🦎-' + operations);
      assert(await mkdir(path, { mode: 0o700 }) === undefined, 'nonrecursive mkdir returns undefined');
      const stat = await fsp.stat(path);
      assert(stat.isDirectory() && (stat.mode & 0o777) === 0o700, 'real private directory');
    });
    await check(lane + 'mkdir recursive first ancestor', async () => {
      const parent = join(base, 'parent-' + operations); const child = join(parent, 'child', 'leaf');
      assert(await mkdir(child, { recursive: true }) === parent, 'return first created ancestor');
      assert((await fsp.stat(child)).isDirectory(), 'real nested directory');
      assert(await mkdir(child, { recursive: true }) === undefined, 'existing directory returns undefined');
    });
    await check(lane + 'mkdir existing error', async () => {
      const path = join(base, 'existing-' + operations); await fsp.mkdir(path); let caught;
      try { await mkdir(path); } catch (error) { caught = error; }
      expected(caught, 'EEXIST', path);
    });
    await check(lane + 'mkdir missing parent', async () => {
      const path = join(base, 'missing-' + operations, 'leaf'); let caught;
      try { await mkdir(path); } catch (error) { caught = error; }
      expected(caught, 'ENOENT', path);
    });
    await check(lane + 'mkdir file preserved', async () => {
      const path = join(base, 'file-' + operations); await fsp.writeFile(path, 'keep'); let caught;
      try { await mkdir(path, { recursive: true }); } catch (error) { caught = error; }
      expected(caught, 'EEXIST', path);
      assert(await fsp.readFile(path, 'utf8') === 'keep', 'preserve existing file');
    });
    await check(lane + 'rm actual file', async () => {
      const path = join(base, 'remove-file-' + operations); await fsp.writeFile(path, 'remove');
      assert(await rm(path) === undefined && !fs.existsSync(path), 'unlink actual file');
    });
    await check(lane + 'rm directory guard', async () => {
      const path = join(base, 'protected-' + operations); await fsp.mkdir(path); await fsp.writeFile(join(path, 'child'), 'keep'); let caught;
      try { await rm(path, { force: true }); } catch (error) { caught = error; }
      expected(caught, 'ERR_FS_EISDIR', path);
      assert(await fsp.readFile(join(path, 'child'), 'utf8') === 'keep', 'force alone never deletes a tree');
    });
    await check(lane + 'rm recursive tree', async () => {
      const path = join(base, 'tree-' + operations); await fsp.mkdir(join(path, 'nested'), { recursive: true });
      await fsp.writeFile(join(path, 'nested', 'child'), 'remove');
      assert(await rm(path, { recursive: true, force: true }) === undefined && !fs.existsSync(path), 'remove actual tree');
    });
    await check(lane + 'rm missing force', async () => {
      const path = join(base, 'absent-' + operations);
      assert(await rm(path, { force: true }) === undefined, 'force ignores missing path');
      let caught; try { await rm(path); } catch (error) { caught = error; }
      expected(caught, 'ENOENT', path);
    });
  }
} finally { await fsp.rm(base, { recursive: true, force: true }); }
if (failures.length) throw new Error('NODE SYNC FS ' + operations + ' checks; failures: ' + failures.join('; '));
console.log('NODE SYNC FS ' + operations + ' CHECKS OK');
