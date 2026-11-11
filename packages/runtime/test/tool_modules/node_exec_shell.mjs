import child, { execSync, execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { readFileSync, realpathSync, existsSync } from 'node:fs';
const [mode, root] = process.argv.slice(2);
function assert(value, label) { if (!value) throw new Error(label); }
function throws(fn) { let error; try { fn(); } catch (caught) { error = caught; } assert(error, 'expected failure'); return error; }
if (mode === 'mirror') {
  const output = execSync("printf actual; printf '\\000\\377diagnostic' >&2");
  console.log('DEFAULT SHELL STDOUT ' + output.toString('hex'));
} else if (mode === 'inherit') {
  const output = execSync("printf inherited; printf native-stderr >&2", { stdio: 'inherit', cwd: root });
  assert(output === null, 'inherited output is not captured');
  console.log(' INHERITED SHELL NULL VERIFIED');
} else if (mode === 'inherit-file') {
  const output = execSync('[ -f /dev/fd/1 ] && [ -f /dev/fd/2 ] && printf descriptor-file; printf file-stderr >&2', { stdio: 'inherit' });
  assert(output === null, 'regular-file descriptors inherited directly');
} else if (mode === 'unsupported') {
  let count = 0;
  for (const options of [{ timeout: 1 }, { shell: 'sh' }, { shell: {} }, { stdio: 'ignore' }, { stdio: ['pipe', 'pipe', 'pipe'] }, { encoding: 'hex' }, { uid: 1 }, { maxBuffer: 33554433 }]) {
    assert(throws(() => execSync('printf launched > unsupported-ran', { cwd: root, ...options })).code === 'ERR_HOME_UNSUPPORTED', 'explicit profile refusal'); count++;
  }
  assert(!existsSync(root + '/unsupported-ran'), 'refused operations did not launch');
  console.log('HOME EXEC SHELL ' + count + ' REFUSALS OK');
} else if (mode === 'contract') {
  const failures = [], labels = [];
  function check(label, fn) { try { fn(); labels.push(label); } catch (error) { failures.push({ label, message: String(error), code: error.code }); } }
  check('module aliases and real binary shell output', () => {
    const req = createRequire(import.meta.url);
    assert(child === req('child_process') && child === req('node:child_process') && child.execSync === execSync, 'module identity');
    const value = execSync("printf '\\000\\377a\\000b'", { stdio: 'pipe' });
    assert(Buffer.isBuffer(value) && value.toString('hex') === '00ff610062', 'actual binary Buffer');
  });
  check('shell expands variables but preserves quoted literals', () => {
    assert(execSync('printf "%s|%s" "$WITNESS" \'$WITNESS;*\'', { env: { WITNESS: 'native value' }, encoding: 'utf8' }) === 'native value|$WITNESS;*', 'real shell quoting');
  });
  check('pipeline and redirection write a real file', () => {
    execSync("printf '\\000\\377physical' | /bin/cat > 'shell result.bin'", { cwd: root });
    assert(readFileSync(root + '/shell result.bin').toString('hex') === '00ff706879736963616c', 'physical redirection');
  });
  check('real cwd and explicit environment', () => {
    assert(execSync('/bin/pwd', { cwd: root + '/cwd ☃', encoding: 'utf8' }).trim() === realpathSync(root + '/cwd ☃'), 'shell cwd');
    assert(execSync('printf "%s|%s" "$WITNESS" "${ABSENT-unset}"', { env: { WITNESS: 'exact' }, encoding: 'utf8' }) === 'exact|unset', 'replacement environment');
  });
  check('default environment reads current public process env', () => {
    const saved = process.env.HOME_SHELL_WITNESS;
    try { process.env.HOME_SHELL_WITNESS = 'live'; assert(execSync('printf "%s" "$HOME_SHELL_WITNESS"', { encoding: 'utf8' }) === 'live', 'live env'); }
    finally { if (saved === undefined) delete process.env.HOME_SHELL_WITNESS; else process.env.HOME_SHELL_WITNESS = saved; }
  });
  check('custom absolute shell executes the command', () => {
    assert(execSync('printf custom', { shell: '/bin/sh', encoding: 'utf8' }) === 'custom', 'custom shell');
  });
  check('boolean and null shell values still invoke a real shell', () => {
    for (const shell of [true, false, null]) assert(execSync('printf "%s" "$A"', { shell, env: { A: 'expanded' }, encoding: 'utf8' }) === 'expanded', 'shell selection');
  });
  check('binary stdin reaches the actual command', () => {
    assert(execSync('/bin/cat', { input: Buffer.from([0, 255, 128, 97]), stdio: 'pipe' }).toString('hex') === '00ff8061', 'binary stdin');
  });
  check('binary view windows stay bounded', () => {
    const data = new Uint8Array([99, 0, 255, 88]);
    assert(execSync('/bin/cat', { input: new DataView(data.buffer, 1, 2), stdio: 'pipe' }).toString('hex') === '00ff', 'view stdin');
  });
  check('UTF-8 input and output preserve NUL and Unicode', () => {
    const input = 'native 🌍\0end'; assert(execSync('/bin/cat', { input, encoding: 'utf8' }) === input, 'UTF-8');
  });
  check('absent input closes stdin', () => {
    assert(execSync('/bin/cat').length === 0 && execSync('/bin/cat', { input: null }).length === 0, 'EOF');
  });
  check('nonzero exit retains actual status and both outputs', () => {
    const e = throws(() => execSync("printf 'out\\000\\377'; printf 'err\\000\\376' >&2; exit 7", { stdio: 'pipe' }));
    assert(e.status === 7 && e.signal === null && e.stdout.toString('hex') === '6f757400ff' && e.stderr.toString('hex') === '65727200fe', 'failure output');
    assert(e.output[1] === e.stdout && e.output[2] === e.stderr, 'output identity');
  });
  check('actual shell signal remains a failure', () => {
    const e = throws(() => execSync('printf before; kill -TERM $$', { stdio: 'pipe' }));
    assert(e.status === null && e.signal === 'SIGTERM' && e.stdout.toString() === 'before', 'shell signal');
  });
  check('overflow fails and later commands recover', () => {
    assert(throws(() => execSync('while :; do printf 0123456789; done', { stdio: 'pipe', maxBuffer: 128 })).code === 'ENOBUFS', 'bounded output');
    assert(execSync('printf recovered', { encoding: 'utf8' }) === 'recovered', 'recovery');
  });
  check('missing selected shell reports native spawn failure', () => {
    assert(throws(() => execSync('printf unreachable', { shell: '/no-home-shell-123', stdio: 'pipe' })).code === 'ENOENT', 'missing shell');
  });
  check('command validation and literal execFileSync remain distinct', () => {
    assert(throws(() => execSync('printf x\0bad')).code === 'ERR_INVALID_ARG_VALUE', 'NUL validation');
    assert(throws(() => execSync(42)).code === 'ERR_INVALID_ARG_TYPE', 'type validation');
    assert(execFileSync('/bin/sh', ['-c', 'printf "%s" "$1"', 'sh', '$HOME;literal'], { encoding: 'utf8' }) === '$HOME;literal', 'literal argv preserved');
  });
  if (labels.length + failures.length !== 16) throw new Error('wrong shell exec denominator');
  console.log('NODE EXEC SHELL RESULTS ' + JSON.stringify({ checks: 16, passed: labels.length, failures }));
  if (failures.length) throw new Error('Shell exec contract failed');
  console.log('NODE EXEC SHELL 16 CHECKS OK');
} else throw new Error('Unknown fixture mode');
