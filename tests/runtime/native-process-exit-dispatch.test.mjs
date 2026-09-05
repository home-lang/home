import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { basename } from 'node:path'
import { fileURLToPath } from 'node:url'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const env = { ...process.env, HOME_NATIVE_VM: '1', NO_COLOR: '1' }
for (const name of ['HOME_CORPUS_FULL_VM', 'HOME_NATIVE_RUN', 'HOME_BUN_TEST_EXECUTABLE', 'BUN_DESTRUCT_VM_ON_EXIT']) delete env[name]

function run(source, expectedStatus, expectedLines) {
  const child = spawnSync(process.execPath, ['-e', source], {
    env,
    encoding: 'utf8',
    timeout: 15000,
    maxBuffer: 1024 * 1024,
  })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null, child.stderr)
  const lines = child.stdout.trim().split(/\r?\n/).filter(Boolean)
  if (expectedLines) assert.deepEqual(lines, expectedLines)
  assert.equal(child.stderr, '')
  assert.equal(child.status, expectedStatus, child.stdout)
  return child
}

const workerHelper = `
import { Worker } from 'node:worker_threads';
async function worker(source) {
  const instance = new Worker(source, { eval: true });
  return await new Promise((resolve, reject) => {
    instance.on('error', reject);
    instance.on('exit', resolve);
  });
}
`
const quietWorker = JSON.stringify('process.on("exit", () => {});')

// A worker finishing first must not suppress later workers or the main VM.
run(workerHelper + `
process.on('beforeExit', code => console.log('MAIN_BEFORE', code));
process.on('exit', code => console.log('MAIN_EXIT', code));
for (let i = 0; i < 3; i++) {
  const source = 'process.on("beforeExit", code => console.log("WORKER_BEFORE", ' + i + ', code));'
    + 'process.on("exit", code => console.log("WORKER_EXIT", ' + i + ', code));';
  console.log('WORKER_DONE', i, await worker(source));
}
`, 0, [
  'WORKER_BEFORE 0 0', 'WORKER_EXIT 0 0', 'WORKER_DONE 0 0',
  'WORKER_BEFORE 1 0', 'WORKER_EXIT 1 0', 'WORKER_DONE 1 0',
  'WORKER_BEFORE 2 0', 'WORKER_EXIT 2 0', 'WORKER_DONE 2 0',
  'MAIN_BEFORE 0', 'MAIN_EXIT 0',
])

// Explicit worker exit skips beforeExit, emits exit once, and does not exit
// the parent process. Re-entering exit cannot bypass the native guard.
run(workerHelper + `
process.on('exit', code => console.log('MAIN_EXIT', code));
for (const code of [3, 5]) {
  const source = 'process.on("beforeExit", () => console.log("UNEXPECTED_BEFORE"));'
    + 'process.on("exit", code => { console.log("WORKER_EXIT", code); process._exiting = false; process.exit(code); });'
    + 'process.exit(' + code + '); console.log("UNEXPECTED_AFTER");';
  console.log('WORKER_DONE', await worker(source));
}
`, 0, ['WORKER_EXIT 3', 'WORKER_DONE 3', 'WORKER_EXIT 5', 'WORKER_DONE 5', 'MAIN_EXIT 0'])

run(workerHelper + `
await worker(${quietWorker});
process.on('beforeExit', () => console.log('UNEXPECTED_BEFORE'));
process.on('exit', code => console.log('MAIN_EXIT', code));
process.exit(17);
console.log('UNEXPECTED_AFTER');
`, 17, ['MAIN_EXIT 17'])

run(workerHelper + `
await worker(${quietWorker});
process.on('exit', code => { console.log('MAIN_EXIT', code); process._exiting = false; process.exit(code); });
process.exit(23);
`, 23, ['MAIN_EXIT 23'])

run(workerHelper + `
await worker(${quietWorker});
process.on('exit', code => { console.log('MAIN_EXIT', code); process.exitCode = 19; });
`, 19, ['MAIN_EXIT 0'])

// beforeExit can schedule more work, but the final exit still runs once.
run(workerHelper + `
await worker(${quietWorker});
let count = 0;
process.on('beforeExit', () => {
  console.log('BEFORE', ++count);
  if (count === 1) setImmediate(() => console.log('MORE_WORK'));
});
process.on('exit', code => console.log('MAIN_EXIT', code));
`, 0, ['BEFORE 1', 'MORE_WORK', 'BEFORE 2', 'MAIN_EXIT 0'])

// This is the actual Node-core fixture guard: its missing callback must fail
// even when a worker has already finished, not become a false-positive pass.
const common = fileURLToPath(new URL('../../packages/runtime/test/test/js/node/test/common/index.js', import.meta.url))
const missing = run(workerHelper + `
require(${JSON.stringify(common)}).mustCall();
await worker(${quietWorker});
`, 1)
assert.match(missing.stdout, /Mismatched noop function calls\. Expected exactly 1, actual 0\./)

// Worker shutdown must report thrown exit assertions before disabling its
// uncaught-exception handler. Observe both the error and the failed exit code.
const throwingWorkers = [
  { code: 1, source: 'process.on("exit", () => { throw new Error("worker exit guard"); });' },
  { code: 1, source: `const common = require(${JSON.stringify(common)});
   process.on('exit', common.mustNotCall('worker exit assertion'));` },
  // The finite timer deliberately keeps the loop alive after a fatal error;
  // the parent-side 15s bound catches a failure to stop beforeExit draining.
  { code: 1, source: `process.on('beforeExit', () => {
    setTimeout(() => console.log('UNEXPECTED_AFTER_FATAL'), 60000);
    throw new Error('worker beforeExit guard');
  });` },
  { code: 7, source: `process.on('uncaughtException', () => {
    throw new Error('worker nested guard');
  });
  throw new Error('worker outer guard');` },
]
run(workerHelper + `
process.on('exit', code => console.log('MAIN_EXIT', code));
for (const { source, code: expectedCode } of ${JSON.stringify(throwingWorkers)}) {
  const instance = new Worker(source, { eval: true });
  const errors = [];
  instance.on('error', error => errors.push(error));
  const code = await new Promise(resolve => instance.on('exit', resolve));
  const assert = require('node:assert/strict');
  assert.equal(errors.length, 1, 'worker exit assertion must emit one error');
  assert.match(errors[0].message, /worker (exit|beforeExit|nested) (guard|assertion)/);
  assert.equal(code, expectedCode, 'worker assertion must fail the worker');
  console.log('WORKER_ASSERTION_FAILED', code);
}
`, 0, ['WORKER_ASSERTION_FAILED 1', 'WORKER_ASSERTION_FAILED 1', 'WORKER_ASSERTION_FAILED 1', 'WORKER_ASSERTION_FAILED 7', 'MAIN_EXIT 0'])

console.log('native per-VM process exit dispatch regressions passed')
