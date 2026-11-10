import buffer, { Buffer, constants, kMaxLength } from 'node:buffer';
import alias from 'buffer';
function check(value, message) { if (!value) throw new Error(message); }
check(buffer === alias && buffer.Buffer === Buffer, 'Buffer module identity');
check(buffer.constants === constants && buffer.kMaxLength === kMaxLength, 'named limit exports');
check(Number.isSafeInteger(constants.MAX_LENGTH) && constants.MAX_LENGTH > 1024, 'real positive buffer length bound');
check(kMaxLength === constants.MAX_LENGTH, 'legacy maximum length alias');
let operations = 0;
for (const size of [0, 1, 17, 64, 1024]) {
  const bytes = Buffer.alloc(size, 173);
  check(Buffer.isBuffer(bytes) && bytes.length === size, 'actual bounded allocation');
  check(Array.from(bytes).every(value => value === 173), 'actual allocated bytes');
  operations++;
}
for (const size of [constants.MAX_LENGTH + 1, Infinity, -Infinity, -1, NaN]) {
  let error;
  try { Buffer.alloc(size); } catch (thrown) { error = thrown; }
  check(error instanceof RangeError, 'out of range allocation must throw before allocating');
  operations++;
}
const data = Buffer.from([1, 2, 3, 4]);
for (const result of [data.subarray(1, 3), data.slice(1, 3), data.map(value => value + 1), data.filter(value => value > 2)]) {
  check(Buffer.isBuffer(result), 'managed Buffer species');
  operations++;
}
check(Buffer.from(data.buffer, data.byteOffset + 1, 2).toString('hex') === '0203', 'actual borrowed byte window');
operations++;
check(Buffer.alloc(3.9).length === 3, 'fractional allocation size truncates');
operations++;
check(operations === 16, 'Buffer limit operation denominator ' + operations);
