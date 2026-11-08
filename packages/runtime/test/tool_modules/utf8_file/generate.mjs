// Reference-only generator. Expectations come from Node's actual UTF-8 decoder.
import { writeFileSync } from 'node:fs';
const bytes = [];
for (let first = 0; first < 256; first++) {
  for (let second = 0; second < 256; second++) bytes.push(first, second, 47);
}
const boundaries = [0, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF];
for (const point of boundaries) bytes.push(...Buffer.from(String.fromCodePoint(point)), 47);
for (const sequence of [[0xEF, 0xBB, 0xBF], [0xE0, 0xA0, 0x80], [0xED, 0xA0, 0x80], [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF0, 0x9F, 0x92], [0xE2, 0x82]]) {
  for (let length = 1; length <= sequence.length; length++) bytes.push(...sequence.slice(0, length), 47);
}
const data = Buffer.from(bytes);
writeFileSync(new URL('./pairs.bin', import.meta.url), data);
writeFileSync(new URL('./expected.json', import.meta.url), JSON.stringify({ node: process.version, pairs: 65536, text: data.toString('utf8') }) + '\n');
