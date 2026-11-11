import buffer, { Buffer, constants } from 'node:buffer';
import { createRequire } from 'node:module';
import { writeFileSync, readFileSync } from 'node:fs';
const [mode, path] = process.argv.slice(2);
function assert(value, label) { if (!value) throw new Error(label); }
function throws(fn) { let error; try { fn(); } catch (caught) { error = caught; } assert(error, 'expected failure'); return error; }
if (mode === 'guards') {
  for (const method of ['allocUnsafe', 'allocUnsafeSlow']) assert(throws(() => Buffer[method](constants.MAX_LENGTH + 1)).code === 'ERR_OUT_OF_RANGE', 'bounded allocation');
  assert(throws(() => new Buffer(1)).code === 'ERR_HOME_UNSUPPORTED', 'legacy constructor remains refused');
  for (const method of ['allocUnsafe', 'allocUnsafeSlow']) for (const alignment of [64, {}]) assert(throws(() => Buffer[method](8, alignment)).code === 'ERR_HOME_UNSUPPORTED', 'aligned allocation explicitly refused');
  console.log('HOME BUFFER UNSAFE 7 PROFILE GUARDS OK');
} else if (mode === 'contract') {
  const failures = [], labels = [];
  function check(label, fn) { try { fn(); labels.push(label); } catch (error) { failures.push({ label, message: String(error), code: error.code }); } }
  const methods = [Buffer.allocUnsafe, Buffer.allocUnsafeSlow];
  check('named/default/CJS aliases export the real allocation methods', () => {
    const req = createRequire(import.meta.url);
    assert(buffer === req('buffer') && buffer === req('node:buffer') && Buffer === buffer.Buffer && Buffer === globalThis.Buffer, 'module identity');
    assert(methods.every(fn => typeof fn === 'function'), 'allocation function signature');
  });
  check('zero and ordinary byte lengths produce genuine views', () => {
    for (const allocate of methods) for (const size of [0, 1, 8, 8192, 9000]) {
      const b = allocate(size); assert(Buffer.isBuffer(b) && b instanceof Uint8Array && b.length === size && b.byteLength === size, 'managed view size');
    }
  });
  check('fractional lengths truncate and negative zero stays zero', () => {
    for (const allocate of methods) assert(allocate(3.9).length === 3 && allocate(-0).length === 0, 'numeric normalization');
  });
  check('actual allocated bytes are writable and readable', () => {
    for (const allocate of methods) { const b = allocate(4); b.set([0, 255, 128, 97]); assert(b.toString('hex') === '00ff8061', 'binary writes'); }
  });
  check('separate allocations cannot overwrite each other', () => {
    for (const allocate of methods) { const a = allocate(256), b = allocate(256); a.fill(0xa5); b.fill(0x5a); assert(a.every(x => x === 0xa5) && b.every(x => x === 0x5a), 'independent visible windows'); }
  });
  check('subarray and slice retain actual shared bytes', () => {
    for (const allocate of methods) { const b = allocate(8); b.fill(1); const a = b.subarray(2, 4), s = b.slice(4, 6); a.fill(0xff); s.fill(0x80); assert(Buffer.isBuffer(a) && b.toString('hex') === '0101ffff80800101', 'shared view storage'); }
  });
  check('non-numeric sizes fail without coercion', () => {
    for (const allocate of methods) for (const size of ['3', null, undefined, {}, new Number(3), 1n]) assert(throws(() => allocate(size)).code === 'ERR_INVALID_ARG_TYPE', 'type error');
  });
  check('negative and nonfinite sizes fail', () => {
    for (const allocate of methods) for (const size of [-1, NaN, Infinity, -Infinity]) assert(throws(() => allocate(size)).code === 'ERR_OUT_OF_RANGE', 'range error');
  });
  check('undefined alignment and unused third arguments preserve allocation', () => {
    const poison = { toString() { throw new Error('extra argument converted'); } };
    for (const allocate of methods) { const b = allocate(3, undefined, poison); b.fill(7); assert(b.toString('hex') === '070707', 'extra arguments'); }
  });
  check('detached methods ignore their receiver', () => {
    for (const allocate of methods) { const b = Reflect.apply(allocate, null, [2]); b.fill(0xfe); assert(b.toString('hex') === 'fefe', 'detached call'); }
  });
  check('public alloc and global Uint8Array replacement cannot intercept storage', () => {
    const alloc = Buffer.alloc, Bytes = globalThis.Uint8Array;
    try {
      Buffer.alloc = globalThis.Uint8Array = function() { throw new Error('mutable public allocator'); };
      for (const allocate of methods) { const b = allocate(4); b.fill(0xaa); assert(b.toString('hex') === 'aaaaaaaa', 'captured allocation'); }
    } finally { Buffer.alloc = alloc; globalThis.Uint8Array = Bytes; }
  });
  check('slow allocation has genuine unpooled backing storage', () => {
    for (const size of [1, 8, 9000]) { const b = Buffer.allocUnsafeSlow(size); assert(b.byteOffset === 0 && b.buffer.byteLength === size, 'slow standalone allocation'); }
  });
  check('existing initialized allocation retains its fill behavior', () => {
    assert(Buffer.alloc(4, 0x5a).toString('hex') === '5a5a5a5a', 'safe allocation');
  });
  check('native filesystem writes preserve a full binary allocation', () => {
    const b = Buffer.allocUnsafe(65536);
    for (let i = 0; i < b.length; i++) b[i] = i % 251;
    writeFileSync(path, b);
    const loaded = readFileSync(path);
    assert(loaded.length === b.length && loaded.every((value, index) => value === index % 251), 'physical full byte roundtrip');
  });
  if (labels.length + failures.length !== 14) throw new Error('wrong unsafe allocation denominator');
  console.log('NODE BUFFER UNSAFE RESULTS ' + JSON.stringify({ checks: 14, passed: labels.length, failures }));
  if (failures.length) throw new Error('Buffer allocation contract failed');
  console.log('NODE BUFFER UNSAFE 14 CHECKS OK');
} else throw new Error('Unknown fixture mode');
