import { Buffer } from 'node:buffer';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const failures = [], passed = [];
function group(name, fn) { try { if (!fn()) throw new Error('predicate failed'); passed.push(name); } catch (e) { failures.push({ name, error: String(e) }); } }
const frozen = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'buffer_base64_oracles.json'), 'utf8'));
if (frozen.node !== 'v26.10.0' || frozen.cases.length !== 84) throw new Error('Base64 oracle identity/denominator mismatch');
for (let i = 0; i < frozen.cases.length; ++i) {
  const c = frozen.cases[i];
  group('decode-and-length-' + i, () => Buffer.from(c.text, 'base64').toString('hex') === c.base64
    && Buffer.from(c.text, 'base64url').toString('hex') === c.base64url
    && Buffer.byteLength(c.text, 'base64') === c.size && Buffer.byteLength(c.text, 'base64url') === c.urlSize);
}
if (frozen.writes.length !== 28) throw new Error('Write oracle denominator mismatch');
for (let i = 0; i < frozen.writes.length; ++i) {
  const c = frozen.writes[i];
  group('write-oracle-' + i, () => {
    const buffer = Buffer.alloc(8, 204); let written, error;
    try { written = buffer.write(...c.args); } catch (e) { error = e.code || e.name; }
    return written === c.written && error === c.error && buffer.toString('hex') === c.hex;
  });
}
for (const [text, encoded] of [['', ''], ['f', 'Zg=='], ['fo', 'Zm8='], ['foo', 'Zm9v'], ['foob', 'Zm9vYg=='], ['fooba', 'Zm9vYmE='], ['foobar', 'Zm9vYmFy']])
  group('rfc4648-' + text, () => Buffer.from(text).toString('base64') === encoded && Buffer.from(encoded, 'base64').toString() === text);
group('url-alphabet-and-padding', () => Buffer.from([251, 255, 255]).toString('base64') === '+///' && Buffer.from([251, 255, 255]).toString('base64url') === '-___' && Buffer.from([255]).toString('base64url') === '_w');
group('visible-subarray', () => Buffer.from([91, 7, 11, 93]).subarray(1, 3).toString('base64') === 'Bws=');
group('start-end-window', () => Buffer.from([91, 7, 11, 93]).toString('base64', 1, 3) === 'Bws=');
group('write-short-buffer', () => { const b = Buffer.alloc(2); return b.write('Zm9v', 0, 2, 'base64') === 2 && b.toString() === 'fo'; });
group('fill-decoded-pattern', () => Buffer.alloc(5, 'Bws=', 'base64').toString('hex') === '070b070b07');
group('case-insensitive-names', () => Buffer.from('Zg==', 'BASE64').toString('BASE64URL') === 'Zg');
const physical = Buffer.alloc(65536);
for (let i = 0; i < physical.length; ++i) physical[i] = (i * 73 + 19) & 255;
const base64 = physical.toString('base64'), url = physical.toString('base64url');
group('65536-byte-roundtrip', () => Buffer.from(base64, 'base64').every((b, i) => b === physical[i]) && Buffer.from(url, 'base64url').length === physical.length && Buffer.from(url, 'base64url').every((b, i) => b === physical[i]));
console.log('BUFFER BASE64 RESULTS ' + JSON.stringify({ groups: passed.length + failures.length, passed: passed.length, failures }));
console.log('BUFFER BASE64 PHYSICAL ' + JSON.stringify({ bytes: physical.length, base64, base64url: url }));
if (failures.length) throw new Error('Actual base64 codec contract failed');
console.log('BUFFER BASE64 ' + passed.length + ' GROUPS OK');
