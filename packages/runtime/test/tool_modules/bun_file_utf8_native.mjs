import { readFileSync } from 'node:fs';
const expected = JSON.parse(readFileSync(import.meta.dir + '/utf8_file/expected.json', 'utf8'));
const value = await Bun.file(import.meta.dir + '/utf8_file/pairs.bin').text();
if (value !== expected.text) throw new Error('file UTF-8 differs from the 65,536-pair Node oracle');
console.log('OK actual file UTF-8 matches 65536 byte pairs and multibyte boundaries');
