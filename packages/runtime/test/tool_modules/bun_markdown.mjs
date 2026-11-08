import { markdown } from 'bun';
import { readFileSync } from 'node:fs';
import { Buffer } from 'node:buffer';
if (markdown !== Bun.markdown) throw new Error('Markdown module identity');
const rows = JSON.parse(readFileSync(import.meta.dir + '/markdown/fixtures.json', 'utf8'));
for (const row of rows) {
  const actual = markdown.html(row.input, row.options);
  if (actual !== row.expected) throw new Error(row.name + ': ' + JSON.stringify({ actual, expected: row.expected }));
}
const binaryRows = JSON.parse(readFileSync(import.meta.dir + '/markdown/binary-fixtures.json', 'utf8'));
for (const row of binaryRows) {
  const actual = markdown.html(new Uint8Array(row.bytes));
  if (actual !== row.expected) throw new Error('binary ' + JSON.stringify(row.bytes) + ': ' + JSON.stringify({ actual, expected: row.expected }));
}
const input = '# Bytes é😀\n';
const expected = '<h1>Bytes é😀</h1>\n';
const bytes = Buffer.from(input);
const padded = new Uint8Array(bytes.length + 4);
padded.set(bytes, 2);
const range = padded.subarray(2, bytes.length + 2);
const view = new DataView(padded.buffer, 2, bytes.length);
for (const value of [bytes, range, view, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), new String(input)]) {
  if (markdown.html(value) !== expected) throw new Error('actual string/binary input changed');
}
const typedBuffer = new ArrayBuffer(32);
const typedBytes = new Uint8Array(typedBuffer);
typedBytes.fill(32);
typedBytes.set([35, 32, 116, 121, 112, 101, 100, 10]);
for (const Type of [Uint8Array, Int8Array, Uint8ClampedArray, Uint16Array, Int16Array, Uint32Array, Int32Array, Float32Array, Float64Array, BigInt64Array, BigUint64Array]) {
  if (markdown.html(new Type(typedBuffer)) !== '<h1>typed</h1>\n') throw new Error('typed byte view changed');
}
for (const value of [new Uint8Array(0), new ArrayBuffer(0), new DataView(new ArrayBuffer(0))]) {
  if (markdown.html(value) !== '') throw new Error('empty binary input changed');
}
for (const value of [undefined, null, 1, true, {}, [], Object.create(ArrayBuffer.prototype)]) {
  let threw = false;
  try { markdown.html(value); } catch (error) { threw = error instanceof TypeError; }
  if (!threw) throw new Error('invalid Markdown input accepted');
}
let coerced = false;
try { markdown.html({ toString() { coerced = true; return '# fake'; } }); } catch {}
if (coerced) throw new Error('arbitrary object was coerced');
const mutable = new Uint8Array([35, 32, 111, 108, 100, 10]);
const mutationOptions = { get tables() { mutable.set([110, 101, 119], 2); return true; } };
if (markdown.html(mutable, mutationOptions) !== '<h1>new</h1>\n') throw new Error('ordinary byte mutation was lost');
const marker = {};
try { markdown.html('text', { get tables() { throw marker; } }); throw new Error('getter did not run'); }
catch (error) { if (error !== marker) throw error; }
const encode = JSON.stringify;
try {
  JSON.stringify = function() { throw new Error('public JSON encoder called'); };
  if (markdown.html('# Private\n') !== '<h1>Private</h1>\n') throw new Error('private encoding changed');
}
finally { JSON.stringify = encode; }
console.log('OK actual Markdown HTML ' + rows.length + ' text/options + ' + binaryRows.length + ' binary cases and input contracts');
