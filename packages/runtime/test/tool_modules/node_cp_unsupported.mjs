import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { join } from 'node:path';
const root = process.env.HOME_TOOL_COPY_FIXTURE;
if (!root) throw new Error('Real copy fixtures must be prepared by tool_copy_fixture.py');
let checks = 0;
for (const sync of [false, true]) {
  const cp = sync ? (s, d, o) => fs.cpSync(s, d, o) : (s, d, o) => fsp.cp(s, d, o);
  const cases = [
    ['source-link', {}], ['source-fifo', {}],
    ['direct.bin', { dereference: true }],
    ['direct.bin', { preserveTimestamps: true }],
    ['direct.bin', { verbatimSymlinks: true }],
    ['direct.bin', { mode: 1 }],
  ];
  for (const [name, options] of cases) {
    const destination = join(root, 'output', 'unsupported-' + sync + '-' + checks);
    let error;
    try { await cp(join(root, 'input', name), destination, options); } catch (caught) { error = caught; }
    if (!error || error.code !== 'ERR_HOME_UNSUPPORTED' || fs.existsSync(destination)) {
      throw new Error('Unsupported copy must fail explicitly without fabricating output: ' + name);
    }
    checks++;
  }
}
console.log('NODE CP UNSUPPORTED ' + checks + ' CHECKS OK');
