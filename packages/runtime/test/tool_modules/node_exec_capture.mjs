import child, { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { realpathSync, existsSync } from 'node:fs';
const [python, helper, root] = process.argv.slice(2);
const requireHere = createRequire(import.meta.url);
const failures = [], labels = [];
function assert(value, label) { if (!value) throw new Error(label); }
function check(label, fn) { try { fn(); labels.push(label); } catch (error) { failures.push({ label, message: String(error), code: error.code }); } }
function call(mode, options = {}, extra = []) { return execFileSync(python, [helper, mode, ...extra], { stdio: 'pipe', ...options }); }
function throws(fn) { let error; try { fn(); } catch (caught) { error = caught; } assert(error, 'expected failure'); return error; }
check('module aliases, genuine Buffer default and binary bytes', () => {
  assert(child === requireHere('child_process') && child === requireHere('node:child_process') && child.execFileSync === execFileSync, 'module identity');
  const output = execFileSync(python, [helper, 'binary']);
  assert(Buffer.isBuffer(output) && output.toString('hex') === '00ff80610062', 'actual binary output');
});
check('EOF with absent and null input', () => {
  assert(call('echo').length === 0 && call('echo', { input: null }).length === 0, 'stdin EOF');
});
check('UTF-8 string input preserves NUL and Unicode', () => {
  const text = 'native 🌍\0after';
  assert(call('echo', { input: text, encoding: 'utf8' }) === text, 'text roundtrip');
});
check('binary views preserve byte offset and length', () => {
  const data = new Uint8Array([99, 0, 255, 128, 77]);
  assert(call('echo', { input: data.subarray(1, 4) }).toString('hex') === '00ff80', 'Uint8Array window');
  assert(call('echo', { input: new DataView(data.buffer, 1, 3) }).toString('hex') === '00ff80', 'DataView window');
});
check('output UTF-8 decoding replaces invalid bytes and keeps NUL', () => {
  assert(call('invalid-utf8', { encoding: 'utf-8' }) === '\ufffda\0b', 'UTF-8 decode');
});
check('real cwd and replacement environment', () => {
  const out = JSON.parse(call('metadata', { cwd: root + '/cwd ☃', env: { HOME_EXEC_WITNESS: 'explicit 🟢' }, encoding: 'utf8', windowsHide: true }));
  assert(out.cwd === realpathSync(root + '/cwd ☃') && out.witness === 'explicit 🟢' && out.path === null, 'cwd/environment');
});
check('default environment reads current public process env', () => {
  const saved = process.env.HOME_EXEC_WITNESS;
  try {
    process.env.HOME_EXEC_WITNESS = 'live';
    assert(JSON.parse(call('metadata', { encoding: 'utf8' })).witness === 'live', 'live env');
  } finally {
    if (saved === undefined) delete process.env.HOME_EXEC_WITNESS; else process.env.HOME_EXEC_WITNESS = saved;
  }
});
check('arguments stay literal without a shell', () => {
  const args = ['a b', '$HOME', ';touch ' + root + '/bad', '🌍'];
  assert(JSON.stringify(JSON.parse(call('argv', { encoding: 'utf8' }, args))) === JSON.stringify(args) && !existsSync(root + '/bad'), 'literal argv');
});
check('nonzero exit retains actual status and both binary outputs', () => {
  const e = throws(() => call('failure'));
  assert(e.status === 7 && e.signal === null && e.stdout.toString('hex') === '6f757400ff' && e.stderr.toString('hex') === '65727200fe', 'failure outputs');
  assert(e.output[1] === e.stdout && e.output[2] === e.stderr, 'output identity');
});
check('actual termination signal stays a failure', () => {
  const e = throws(() => call('signal'));
  assert(e.status === null && e.signal === 'SIGTERM' && e.stdout.toString('utf8') === 'before signal', 'signal result');
});
check('three pipes make simultaneous progress beyond kernel pipe buffers', () => {
  const out = call('duplex', { input: Buffer.alloc(512 * 1024, 0xa5) });
  assert(out.length === 768 * 1024 && createHash('sha256').update(out).digest('hex') === '532653898c736fd6af28fe3764dd51fd28a40fb4caf3ba1eceacfc83d98ffcb7', 'duplex data');
});
check('output overflow fails and later executions recover', () => {
  const e = throws(() => call('overflow', { maxBuffer: 128 }));
  assert(e.code === 'ENOBUFS', 'output limit error');
  assert(call('binary').toString('hex') === '00ff80610062', 'recovery after failure');
});
check('spawn failures and invalid argv never report success', () => {
  assert(throws(() => execFileSync('/no-home-capture-binary-123', [])).code === 'ENOENT', 'missing executable');
  throws(() => execFileSync(python, ['a\0b']));
  throws(() => call('echo', { env: { A: 'x\0y' } }));
});
check('early stdin closure preserves final output and reports EPIPE', () => {
  const e = throws(() => call('early-close', { input: Buffer.alloc(512 * 1024, 0xa5) }));
  assert(e.code === 'EPIPE' && e.status === 0 && e.signal === null && e.stdout.toString('utf8') === 'done', 'EPIPE result');
});
if (labels.length + failures.length !== 14) throw new Error('wrong captured exec denominator');
console.log('NODE EXEC CAPTURE RESULTS ' + JSON.stringify({ checks: 14, passed: labels.length, failures }));
if (failures.length) throw new Error('Captured exec contract failed');
console.log('NODE EXEC CAPTURE 14 CHECKS OK');
