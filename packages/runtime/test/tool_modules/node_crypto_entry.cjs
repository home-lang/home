const crypto = require('node:crypto');
const { Buffer } = require('node:buffer');
if (crypto !== require('crypto')) throw new Error('crypto alias identity');
const sizes = [0, 1, 1.9, 16, 32, 65537];
for (const size of sizes) {
  const bytes = crypto.randomBytes(size);
  if (!Buffer.isBuffer(bytes) || !ArrayBuffer.isView(bytes) || bytes.length !== Math.floor(size)) throw new Error('real random Buffer storage');
}
// These are entropy-transport witnesses, not a statistical certification.
const first = crypto.randomBytes(4096);
const second = crypto.randomBytes(4096);
if (first.equals(second) || first.every(byte => byte === 0)) throw new Error('entropy was not delivered to Buffer');
const invalid = [];
for (const size of ['1', null, undefined, 1n, -1, -0.1, NaN, Infinity, 0x80000000]) {
  try {
    crypto.randomBytes(size);
    throw new Error('invalid size accepted');
  }
  catch (error) {
    if (!['ERR_INVALID_ARG_TYPE', 'ERR_OUT_OF_RANGE'].includes(error.code)) throw error;
    invalid.push([error.name, error.code]);
  }
}
for (const callback of [null, 0, {}]) {
  try {
    crypto.randomBytes(0, callback);
    throw new Error('invalid callback accepted');
  }
  catch (error) {
    if (error.code !== 'ERR_INVALID_ARG_TYPE') throw error;
  }
}
console.log(JSON.stringify({ sizes: sizes.map(Math.floor), invalid }));
