import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
const [python, helper, root] = process.argv.slice(2);
const cases = [
  { timeout: 1 }, { killSignal: 'SIGTERM' }, { shell: true }, { uid: 0 }, { gid: 0 },
  { stdio: ['pipe', 'pipe', 'pipe'] }, { stdio: 'ignore' }, { encoding: 'hex' },
  { maxBuffer: 32 * 1024 * 1024 + 1 }, { input: new ArrayBuffer(1) },
];
let count = 0;
for (const options of cases) {
  let error;
  try { execFileSync(python, [helper, 'touch', root + '/unsupported-ran'], options); } catch (caught) { error = caught; }
  if (!error) throw new Error('Unsupported exec mode succeeded');
  // Raw ArrayBuffer is invalid input (typed views are supported).
  if (options.input ? error.code !== 'ERR_INVALID_ARG_TYPE' : error.code !== 'ERR_HOME_UNSUPPORTED') throw error;
  count++;
}
if (count !== 10 || existsSync(root + '/unsupported-ran')) throw new Error('Unsupported exec was launched');
console.log('HOME EXEC CAPTURE 10 REFUSALS OK');
