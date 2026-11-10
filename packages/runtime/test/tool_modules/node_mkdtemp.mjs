import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const base = join(tmpdir(), 'home-mkdtemp-' + randomUUID());
await fsp.mkdir(base);
let operations = 0;
const failures = [];
function assert(value, message) { if (!value) throw new Error(message); }
async function check(name, run) {
  operations++;
  try { await run(); } catch (error) { failures.push(name + ': ' + error.message); }
}
try {
  for (const sync of [false, true]) {
    for (const [name, options] of [['default', undefined], ['utf8', 'utf8'], ['object', { encoding: 'utf-8' }], ['buffer', { encoding: 'buffer' }]]) {
      await check((sync ? 'sync' : 'promise') + ' ' + name, async () => {
        const prefix = join(base, 'espaço-🦎-' + operations + '-');
        const result = sync ? fs.mkdtempSync(prefix, options) : await fsp.mkdtemp(prefix, options);
        assert(Buffer.isBuffer(result) === (name === 'buffer'), 'preserve output type');
        const path = Buffer.isBuffer(result) ? result.toString('utf8') : result;
        assert(path.startsWith(prefix) && /^[A-Za-z0-9]{6}$/.test(path.slice(prefix.length)), 'append six random characters');
        const stat = await fsp.stat(path);
        assert(stat.isDirectory() && (stat.mode & 0o777) === 0o700, 'create a private actual directory');
        await fsp.writeFile(join(path, 'marker'), 'real');
        assert(await fsp.readFile(join(path, 'marker'), 'utf8') === 'real', 'directory is usable');
      });
    }
    await check((sync ? 'sync' : 'promise') + ' missing parent', async () => {
      const prefix = join(base, 'missing-parent', 'child-'); let caught;
      try { if (sync) fs.mkdtempSync(prefix); else await fsp.mkdtemp(prefix); } catch (error) { caught = error; }
      assert(caught && caught.code === 'ENOENT', 'propagate missing parent');
      assert(!fs.existsSync(join(base, 'missing-parent')), 'do not recursively create parents');
    });
  }
  await check('distinct real directories', async () => {
    const names = new Set();
    for (let index = 0; index < 32; index++) {
      const path = await fsp.mkdtemp(join(base, 'distinct-'));
      assert((await fsp.stat(path)).isDirectory(), 'each result exists');
      names.add(path);
    }
    assert(names.size === 32, 'each result is a distinct creation');
  });
  await check('encoding getter supplies result', async () => {
    let reads = 0;
    const path = await fsp.mkdtemp(join(base, 'getter-'), { get encoding() { reads++; return 'utf8'; } });
    assert(reads > 0 && (await fsp.stat(path)).isDirectory(), 'use the supplied encoding');
    // Node 26 reads this getter three times; Bun reads it once. Record the
    // difference without claiming a shared getter-count contract.
    console.log('NODE MKDTEMP ENCODING READS ' + reads);
  });
  await check('encoding getter exception identity', async () => {
    const sentinel = new Error('encoding getter'); let caught;
    try { await fsp.mkdtemp(join(base, 'throw-'), { get encoding() { throw sentinel; } }); } catch (error) { caught = error; }
    assert(caught === sentinel, 'preserve getter exception');
  });
} finally { await fsp.rm(base, { recursive: true, force: true }); }
if (failures.length) throw new Error('NODE MKDTEMP ' + operations + ' checks; failures: ' + failures.join('; '));
console.log('NODE MKDTEMP ' + operations + ' CHECKS OK');
