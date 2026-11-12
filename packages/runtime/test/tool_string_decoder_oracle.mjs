// Refresh intentionally with the pinned Node reference; gates consume the saved
// results, never Home's implementation. Per-write output and pending state matter.
import { StringDecoder } from 'node:string_decoder';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
if (process.version !== 'v26.10.0') throw new Error('Use pinned Node v26.10.0');
const cases = [];
function add(encoding, chunks, tail = null) {
  const decoder = new StringDecoder(encoding);
  const expected = chunks.map(chunk => [decoder.write(Buffer.from(chunk)), decoder.lastNeed, decoder.lastTotal]);
  expected.push([tail === null ? decoder.end() : decoder.end(Buffer.from(tail)), decoder.lastNeed, decoder.lastTotal]);
  expected.push([decoder.write(Buffer.from([65])), decoder.lastNeed, decoder.lastTotal]);
  expected.push([decoder.end(), decoder.lastNeed, decoder.lastTotal]);
  cases.push({ encoding, chunks, tail, expected });
}
function partitions(encoding, bytes) {
  add(encoding, [bytes, []]);
  add(encoding, [[], bytes.slice(0, 1), [], bytes.slice(1)]);
  add(encoding, bytes.map(byte => [byte]));
  for (let at = 0; at <= bytes.length; ++at) add(encoding, [bytes.slice(0, at)], bytes.slice(at));
}
for (let byte = 0; byte < 256; ++byte) add('utf8', [[byte], []]);
for (let lead = 192; lead < 256; ++lead) {
  for (const byte of [0, 65, 127, 128, 143, 144, 159, 160, 175, 191, 192, 224, 255]) {
    add('utf8', [[lead], [byte]]);
    add('utf8', [[lead, byte]]);
  }
}
for (const bytes of [[], [226,130,172], [240,159,152,128], [239,187,191], [224,128,128], [237,160,128], [244,144,128,128], [226,130,65], [240,159,65,128]]) partitions('utf8', bytes);
for (const bytes of [[],[65],[65,0],[0,216],[0,220],[0,216,0],[0,216,65],[0,216,0,220],[0,216,0,216],[65,0,0,216,0,220,66,0],[0,220,0,216,0,220]]) partitions('utf16le', bytes);
for (const encoding of ['base64','base64url','ascii','latin1','hex']) {
  for (let length = 0; length < 10; ++length) partitions(encoding, Array.from({length},(_,i)=>(i*73+length*17)&255));
}
let state = 0x5a17;
for (let i = 0; i < 128; ++i) {
  const bytes = [];
  for (let j = 0; j < 1+i%12; ++j) { state=(Math.imul(state,1664525)+1013904223)>>>0; bytes.push(state>>>24); }
  for (const encoding of ['utf8','utf16le','base64','base64url','ascii','latin1','hex']) add(encoding, [bytes.slice(0,1),bytes.slice(1,3),[],bytes.slice(3)]);
}
const out = { node: process.version, cases };
writeFileSync(fileURLToPath(new URL('./tool_modules/string_decoder_oracle.json', import.meta.url)), JSON.stringify(out)+'\n');
console.log('PINNED STRING DECODER ORACLE '+cases.length);
