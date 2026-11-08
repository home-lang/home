import zlib, { gzipSync, gunzipSync, createGzip, Gzip } from 'zlib';
import alias from 'node:zlib';
import { Buffer } from 'node:buffer';
import { Readable, Writable, Transform } from 'node:stream';
import { pipeline, finished } from 'node:stream/promises';
function check(value, message) { if (!value) throw new Error(message); }
function equal(a, b) { return a.length === b.length && Array.from(a).every((byte, i) => byte === b[i]); }
check(zlib === alias && zlib.gzipSync === gzipSync, 'module identity');
const inputs = [Buffer.from(''), Buffer.from('nul\u0000unicode é😀'), Buffer.from(Array.from({ length: 256 }, (value, i) => i)), Buffer.from('abc123'.repeat(1000))];
for (const input of inputs) {
  const before = Array.from(input); const compressed = gzipSync(input); const decoded = gunzipSync(compressed);
  check(compressed[0] === 31 && compressed[1] === 139, 'gzip header');
  check(Buffer.isBuffer(compressed) && Buffer.isBuffer(decoded) && equal(input, decoded), 'actual bytes/brand');
  check(equal(input, before), 'mutated input');
}
check(gzipSync(inputs[3]).length < inputs[3].length, 'no actual compression');
check(gunzipSync(gzipSync('é\u0000😀')).toString() === 'é\u0000😀', 'string encoding');
const raw = new Uint8Array([99, 0, 255, 128, 100]);
check(equal(gunzipSync(gzipSync(raw.subarray(1, 4))), [0, 255, 128]), 'view offset');
const external = Buffer.from([31, 139, 8, 0, 0, 0, 0, 0, 0, 19, 237, 198, 49, 17, 192, 32, 12, 64, 209, 74, 137, 133, 150, 173, 34, 234, 161, 37, 57, 142, 37, 101, 96, 194, 17, 58, 48, 6, 42, 152, 254, 242, 238, 101, 87, 43, 182, 240, 42, 207, 175, 38, 169, 229, 114, 203, 251, 197, 243, 10, 163, 31, 132, 16, 66, 8, 33, 132, 16, 66, 8, 33, 100, 91, 38, 20, 80, 232, 134, 171, 17, 0, 0]);
const externalText = 'independent Node gzip: ' + 'abc123é\u0000'.repeat(500);
check(gunzipSync(external).toString() === externalText, 'independent compressed fixture');
const headerFields = Buffer.from([31, 139, 8, 30, 0, 0, 0, 0, 0, 19, 2, 0, 7, 9, 102, 105, 108, 101, 0, 99, 111, 109, 109, 101, 110, 116, 0, 62, 243, 237, 198, 49, 17, 192, 32, 12, 64, 209, 74, 137, 133, 150, 173, 34, 234, 161, 37, 57, 142, 37, 101, 96, 194, 17, 58, 48, 6, 42, 152, 254, 242, 238, 101, 87, 43, 182, 240, 42, 207, 175, 38, 169, 229, 114, 203, 251, 197, 243, 10, 163, 31, 132, 16, 66, 8, 33, 132, 16, 66, 8, 33, 100, 91, 38, 20, 80, 232, 134, 171, 17, 0, 0]);
check(gunzipSync(headerFields).toString() === externalText, 'independent optional gzip header fields');
const badHeaderCrc = Buffer.from(headerFields); badHeaderCrc[headerFields.length - external.length + 10 - 1] ^= 1;
try { gunzipSync(badHeaderCrc); throw new Error('accepted bad header CRC'); } catch (error) { check(error.code === 'Z_DATA_ERROR', 'header CRC error'); }
for (const bad of [Buffer.from([0, 0]), Buffer.from([31, 139, 0, 0]), Buffer.from('invalid compressed data')]) {
  try { gunzipSync(bad); throw new Error('accepted invalid header'); } catch (error) { check(error.code === 'Z_DATA_ERROR', 'header error'); }
}

check(gunzipSync(Buffer.concat([external, gzipSync('tail'), Buffer.from([0, 0])])).toString() === externalText + 'tail', 'concatenated members');
const corrupt = Buffer.from(external); corrupt[corrupt.length - 8] ^= 1;
try { gunzipSync(corrupt); throw new Error('accepted bad CRC'); } catch (error) { check(error.code === 'Z_DATA_ERROR', 'bad CRC error'); }
const badSize = Buffer.from(external); badSize[badSize.length - 4] ^= 1;
try { gunzipSync(badSize); throw new Error('accepted bad size'); } catch (error) { check(error.code === 'Z_DATA_ERROR', 'bad size error'); }
for (const bad of [Buffer.from(''), external.subarray(0, external.length - 1)]) {
  try { gunzipSync(bad); throw new Error('accepted truncation'); } catch (error) { check(error.code === 'Z_BUF_ERROR', 'truncation error'); }
}
for (const invalid of [null, 42, true, {}, [], Symbol('invalid')]) {
  try { gzipSync(invalid); throw new Error('accepted invalid input'); } catch (error) { check(error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE', 'input error'); }
}
const chunks = []; const zipper = createGzip({ highWaterMark: 1 });
check(zipper instanceof Gzip && zipper instanceof Transform, 'constructor brands');
const sink = new Writable({ write(chunk, encoding, callback) { chunks.push(Buffer.from(chunk)); callback(); } });
await pipeline(Readable.from([inputs[1], inputs[2], inputs[3]]), zipper, sink);
await finished(zipper); await finished(sink);
check(equal(gunzipSync(Buffer.concat(chunks)), Buffer.concat(inputs.slice(1))), 'pipeline data');
check(zipper.writableFinished && zipper.readableEnded && sink.writableFinished, 'real completion');
const direct = new Gzip(); const directChunks = [];
const directResult = new Promise((resolve, reject) => { direct.on('data', chunk => directChunks.push(chunk)); direct.on('end', resolve); direct.on('error', reject); });
direct.write('one'); direct.end('two'); await directResult;
check(gunzipSync(Buffer.concat(directChunks)).toString() === 'onetwo', 'bunfig-style stream flow');
const reason = new Error('actual sink failure'); const failing = new Writable({ write(chunk, encoding, callback) { callback(reason); } });
try { await pipeline(Readable.from(['bytes']), createGzip(), failing); throw new Error('lost sink error'); } catch (error) { check(error === reason, 'sink error identity'); }
console.log('OK real gzip bytes, independent decoding, validation and pipelines');
