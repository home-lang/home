import { inflateSync } from 'node:zlib';
import { Buffer } from 'node:buffer';
function check(value, message) { if (!value) throw new Error(message); }
let operations = 0;
const packed = Buffer.from('789c4b4c2e294dcc5148aa2c492d06001ea104c2', 'hex');
for (const limit of [12, 13, 12.1, 1 << 20, 256 * 1024 * 1024, undefined, NaN]) {
  check(inflateSync(packed, { maxOutputLength: limit }).toString() === 'actual bytes', 'real output at limit ' + limit);
  operations++;
}
for (const limit of [1, 11, 11.9]) {
  let caught;
  try { inflateSync(packed, { maxOutputLength: limit }); } catch (error) { caught = error; }
  check(caught instanceof RangeError && caught.code === 'ERR_BUFFER_TOO_LARGE', 'bounded output rejects ' + limit);
  operations++;
}
for (const limit of [null, true, false, '12', {}, []]) {
  let caught;
  try { inflateSync(packed, { maxOutputLength: limit }); } catch (error) { caught = error; }
  check(caught instanceof TypeError && caught.code === 'ERR_INVALID_ARG_TYPE', 'invalid limit type');
  operations++;
}
for (const limit of [0, -1, 0.5, Infinity, -Infinity, Number.MAX_SAFE_INTEGER + 1]) {
  let caught;
  try { inflateSync(packed, { maxOutputLength: limit }); } catch (error) { caught = error; }
  check(caught instanceof RangeError && caught.code === 'ERR_OUT_OF_RANGE', 'out of range limit ' + limit);
  operations++;
}
const empty = Buffer.from('789c030000000001', 'hex');
check(inflateSync(empty, { maxOutputLength: 1 }).length === 0, 'empty output is below one byte'); operations++;
check(operations === 23, 'inflate output limit denominator ' + operations);
