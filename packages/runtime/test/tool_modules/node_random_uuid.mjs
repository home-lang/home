import crypto, { randomUUID } from 'node:crypto';

let operations = 0;
const failures = [];
const pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
function check(name, run) {
  operations++;
  try { run(); } catch (error) { failures.push(name + ': ' + error.message); }
}
function assert(value, message) {
  if (!value) throw new Error(message);
}
function valid(options) {
  const value = randomUUID(options);
  assert(typeof value === 'string' && pattern.test(value), 'expected an RFC4122 v4 string');
  return value;
}
for (const [name, options] of [
  ['default', undefined], ['empty', {}], ['cached', { disableEntropyCache: false }],
  ['uncached', { disableEntropyCache: true }], ['unset', { disableEntropyCache: undefined }],
  ['null prototype', Object.create(null)], ['inherited', Object.create({ disableEntropyCache: true })],
]) check(name, () => valid(options));

for (const [name, options] of [
  ['null', null], ['array', []], ['string', 'x'], ['number', 1], ['boolean', true],
  ['function', function() {}], ['null cache', { disableEntropyCache: null }],
  ['number cache', { disableEntropyCache: 1 }], ['string cache', { disableEntropyCache: 'true' }],
]) check(name, () => {
  let caught;
  try { randomUUID(options); } catch (error) { caught = error; }
  assert(caught instanceof TypeError && caught.code === 'ERR_INVALID_ARG_TYPE', 'expected Node argument validation');
});

check('entropy modes and repeated calls', () => {
  const seen = new Set();
  for (let index = 0; index < 128; index++) seen.add(valid({ disableEntropyCache: index % 2 === 0 }));
  assert(seen.size === 128, 'UUIDs must not reuse a fixed or repeated value');
});
check('option getter once', () => {
  let reads = 0;
  valid({ get disableEntropyCache() { reads++; return true; } });
  assert(reads === 1, 'read cache option once');
});
check('getter exception identity', () => {
  const sentinel = new Error('cache getter');
  let caught;
  try { randomUUID({ get disableEntropyCache() { throw sentinel; } }); } catch (error) { caught = error; }
  assert(caught === sentinel, 'propagate getter exception');
});
check('unknown option not read', () => valid({ get ignored() { throw new Error('unobserved option'); } }));
check('aliases and detached receiver', () => {
  assert(crypto.randomUUID === randomUUID, 'default/named alias');
  assert(pattern.test(randomUUID.call(null)), 'detached UUID call');
});
check('public randomBytes replacement is isolated', () => {
  const original = crypto.randomBytes;
  crypto.randomBytes = () => { throw new Error('public randomBytes replaced'); };
  try { valid(); } finally { crypto.randomBytes = original; }
});
check('public Uint8Array replacement is isolated', () => {
  const original = globalThis.Uint8Array;
  globalThis.Uint8Array = function() { throw new Error('public constructor replaced'); };
  try { valid(); } finally { globalThis.Uint8Array = original; }
});

if (failures.length) throw new Error('NODE CRYPTO UUID ' + operations + ' checks; failures: ' + failures.join('; '));
console.log('NODE CRYPTO UUID ' + operations + ' CHECKS OK');
