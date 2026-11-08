const { Buffer } = require('node:buffer');
const strings = require('./node_buffer_strings.json');
function check(condition, message) { if (!condition) throw new Error(message); }
check(Buffer === globalThis.Buffer && Buffer === require('buffer').Buffer, 'buffer identity');
const result = {};
result.strings = strings.map(function(text) {
  const bytes = Buffer.from(text);
  check(bytes instanceof Buffer && bytes instanceof Uint8Array && ArrayBuffer.isView(bytes), 'real typed storage');
  return { hex: bytes.toString('hex'), text: bytes.toString(), size: Buffer.byteLength(text) };
});
result.hex = ['abcd', 'abx1', 'a', 'abcd0', '', 'zz', ' A1', '\u0130f'].map(text => Array.from(Buffer.from(text, 'hex')));
const source = new Uint8Array([1, 2, 3, 4]);
const copy = Buffer.from(source);
source[0] = 9;
check(copy[0] === 1, 'typed source must copy');
const shared = Buffer.from(source.buffer, 1, 2);
shared[0] = 8;
check(source[1] === 8, 'ArrayBuffer view must share');
const view = shared.slice(0, 1);
view[0] = 7;
check(shared[0] === 7 && source[1] === 7, 'slice must share real storage');
const sub = copy.subarray(1, 3);
sub[0] = 6;
check(copy[1] === 6 && sub instanceof Buffer, 'subarray must share');
const mapped = copy.map(x => x + 1);
check(mapped instanceof Buffer && mapped[0] === 2 && mapped[1] === 7, 'typed array species');
result.storage = { source: Array.from(source), copy: Array.from(copy), shared: Array.from(shared), mapped: Array.from(mapped) };
const array = Buffer.from([-1, 256, 3.9, NaN, null, '9']);
const serialized = array.toJSON();
result.json = serialized;
check(Buffer.from(serialized).equals(array), 'JSON roundtrip');
const joined = Buffer.concat([Buffer.from('a'), new Uint8Array([98]), Buffer.from('c')], 5);
check(joined.toString('hex') === '6162630000', 'concat actual bytes and zero padding');
result.concat = [joined.toString('hex'), Buffer.concat([joined], 2).toString(), Buffer.concat([]).length];
result.alloc = [Array.from(Buffer.alloc(4)), Array.from(Buffer.alloc(4, 257)), Buffer.alloc(1.9).length];
const mutable = Buffer.from([1, 2, 3]);
mutable.set([8, 9], 1);
result.set = Array.from(mutable);
result.fill = [Buffer.alloc(6, 'ab').toString(), Buffer.alloc(5, Buffer.from([1,2])).toString('hex'), Buffer.from('abcd').fill(1, 10).toString()];
result.byteLengths = [Buffer.byteLength('zz', 'hex'), Buffer.byteLength('hi', 'unknown')];
for (const operation of [() => Buffer.concat([joined], 1.5), () => joined.fill(1, 1.5)]) {
  let rejected;
  try { operation(); } catch (error) { rejected = error; }
  check(rejected && rejected.code === 'ERR_OUT_OF_RANGE', 'fractional range rejected');
}
const empty = Buffer.from('');
check(empty.length === 0 && Buffer.isBuffer(empty) && !Buffer.isBuffer(new Uint8Array()), 'buffer predicate');
result.ranges = [Buffer.from([0xff, 0xc3, 0xa9]).toString(), Buffer.from('abcdef').toString('utf8', 1, 4), Buffer.from('abcdef').slice(-3).toString(), Buffer.from('a').toString('hex', 4), Buffer.from([0xe2, 0x82]).toString()];
const searched = Buffer.from('ababc');
result.search = [searched.indexOf('ab'), searched.indexOf('ab', 1), searched.lastIndexOf('ab'), searched.indexOf(353), searched.includes(Buffer.from('bc')), searched.indexOf(''), searched.lastIndexOf(''), searched.indexOf('ab', -2), searched.lastIndexOf('ab', -2), searched.indexOf('6162', 'hex')];
result.locale = Buffer.from('hello').toLocaleString();
for (const name of [null, '', false, 0]) {
  let rejected;
  try { searched.toString(name); } catch (error) { rejected = error; }
  check(rejected && rejected.code === 'ERR_UNKNOWN_ENCODING', 'invalid toString encoding');
}
let failure;
try { Buffer.from(1); } catch (error) { failure = error; }
check(failure && failure.code === 'ERR_INVALID_ARG_TYPE', 'numeric from rejected');
failure = undefined;
try { Buffer.alloc(-1); } catch (error) { failure = error; }
check(failure && failure.code === 'ERR_OUT_OF_RANGE', 'negative allocation rejected');
console.log(JSON.stringify(result));
