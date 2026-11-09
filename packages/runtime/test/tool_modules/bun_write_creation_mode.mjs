import fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
function check(value, message) { if (!value) throw new Error(message); }
// The build gate starts this process with umask 0; the build parent's mask
// is untouched. These are Bun 1.4.4's two observed pathname creation paths.
const root = join(tmpdir(), 'home-write-modes-' + process.pid + '-' + Date.now());
await fs.promises.mkdir(root);
try {
  const direct = join(root, 'direct.txt');
  const recovered = join(root, 'missing', 'nested', 'file.txt');
  check(await Bun.write(direct, 'é') === 2, 'direct write count');
  check(await Bun.write(recovered, 'é') === 2, 'recovered write count');
  check((await fs.promises.stat(direct)).mode % 512 === 0o664, 'direct creation mode');
  check((await fs.promises.stat(recovered)).mode % 512 === 0o666, 'missing-parent creation mode');
  check((await fs.promises.stat(dirname(recovered))).mode % 512 === 0o777, 'parent creation mode');
  check(fs.readFileSync(direct).toString('hex') === 'c3a9' && fs.readFileSync(recovered).toString('hex') === 'c3a9', 'actual write contents');
  console.log('OK Bun pathname creation modes before umask');
}
finally {
  await fs.promises.rm(root, { recursive: true, force: true });
}
