import { file } from 'bun';
import { Buffer } from 'node:buffer';
const root = import.meta.dir + '/bun_file/';
const originalFrom = Buffer.from;
const originalToString = Buffer.prototype.toString;
try {
  Buffer.from = function() { throw new Error('public Buffer.from called'); };
  Buffer.prototype.toString = function() { throw new Error('public Buffer.toString called'); };
  const source = file(root + 'unicode and spaces%#.txt');
  if (await source.text() !== 'text é\u0000end�') throw new Error('file text decoding changed');
  const json = await file(root + 'data.json').json();
  if (json.name !== 'café' || json.number !== 7) throw new Error('file JSON decoding changed');
  const binary = file(root + 'bytes.bin');
  const bytes = await binary.bytes();
  const buffer = await binary.arrayBuffer();
  if (!(bytes instanceof Uint8Array) || Buffer.isBuffer(bytes) || !(buffer instanceof ArrayBuffer)) throw new Error('managed binary result types changed');
  const view = new Uint8Array(buffer);
  if (bytes.length !== 256 || view.length !== 256) throw new Error('actual binary length changed');
  for (let index = 0; index < 256; index++) if (bytes[index] !== index || view[index] !== index) throw new Error('actual binary bytes changed');
  if (await file(root + 'empty.txt').text() !== '') throw new Error('empty file changed');
}
finally {
  Buffer.from = originalFrom;
  Buffer.prototype.toString = originalToString;
}
console.log('OK file reads independent of public Buffer methods');
