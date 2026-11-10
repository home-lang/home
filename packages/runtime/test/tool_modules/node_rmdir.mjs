import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const base = join(tmpdir(), 'home-rmdir-' + randomUUID());
await fsp.mkdir(base);
let operations = 0;
const failures = [];
async function check(name, run) {
  operations++;
  try { await run(); } catch (error) { failures.push(name + ': ' + error.message); }
}
function assert(value, message) { if (!value) throw new Error(message); }
function expected(error, code, path) {
  assert(error && error.code === code && error.path === path, 'expected ' + code + ' and original path');
}
try {
  for (const sync of [false, true]) {
    for (const options of [undefined, {}]) {
      await check((sync ? 'sync' : 'promise') + ' empty ' + (options ? 'options' : 'default'), async () => {
        const path = join(base, 'empty-' + operations);
        await fsp.mkdir(path);
        const result = sync ? fs.rmdirSync(path, options) : await fsp.rmdir(path, options);
        assert(result === undefined && !fs.existsSync(path), 'remove the actual empty directory');
      });
    }
    await check((sync ? 'sync' : 'promise') + ' missing', async () => {
      const path = join(base, 'missing'); let caught;
      try { if (sync) fs.rmdirSync(path); else await fsp.rmdir(path); } catch (error) { caught = error; }
      expected(caught, 'ENOENT', path);
    });
    await check((sync ? 'sync' : 'promise') + ' file preserved', async () => {
      const path = join(base, 'file-' + operations); await fsp.writeFile(path, 'keep'); let caught;
      try { if (sync) fs.rmdirSync(path); else await fsp.rmdir(path); } catch (error) { caught = error; }
      expected(caught, 'ENOTDIR', path);
      assert(await fsp.readFile(path, 'utf8') === 'keep', 'rmdir must not unlink a file');
    });
    await check((sync ? 'sync' : 'promise') + ' nonempty preserved', async () => {
      const path = join(base, 'nonempty-' + operations); await fsp.mkdir(path);
      await fsp.writeFile(join(path, 'child'), 'keep'); let caught;
      try { if (sync) fs.rmdirSync(path); else await fsp.rmdir(path); } catch (error) { caught = error; }
      expected(caught, 'ENOTEMPTY', path);
      assert(await fsp.readFile(join(path, 'child'), 'utf8') === 'keep', 'rmdir must not delete contents');
    });
  }
  await check('unicode directory', async () => {
    const path = join(base, 'espaço-🦎'); await fsp.mkdir(path); await fsp.rmdir(path);
    assert(!fs.existsSync(path), 'remove full UTF-8 path');
  });
} finally { await fsp.rm(base, { recursive: true, force: true }); }
if (failures.length) throw new Error('NODE RMDIR ' + operations + ' checks; failures: ' + failures.join('; '));
console.log('NODE RMDIR ' + operations + ' CHECKS OK');
