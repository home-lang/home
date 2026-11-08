import stream, { Readable, Writable, Duplex, Transform, PassThrough } from 'node:stream';
import promises, { pipeline, finished } from 'node:stream/promises';
import { createRequire } from 'node:module';
const requireHere = createRequire(import.meta.url);
function check(value, message) { if (!value) throw new Error(message); }
check(stream === requireHere('stream') && stream.Stream === stream, 'stream aliases');
check(promises === requireHere('stream/promises') && promises === stream.promises, 'promise aliases');
const results = {};
const objects = [];
await pipeline(Readable.from([1, { x: 2 }, 3]), new Writable({ objectMode: true, write(value, encoding, callback) { objects.push(value); callback(); } }));
results.objects = objects;

const pull = new Readable({ read() {} });
pull.push(Buffer.from('abcdef'));
const head = pull.read(2).toString();
const pending = pull.read(99);
check(pending === null && pull.readableLength === 4, 'sized read must await enough data');
pull.push(null);
const tail = pull.read(99).toString();
await finished(pull, { cleanup: true });
results.pull = [head, tail, pull.readableLength, pull.readableEnded];
const idle = new Readable({ read() {} });
idle.push(null);
await new Promise(resolve => process.nextTick(resolve));
check(idle.readableEnded === false, 'EOF before consumption is not end');
idle.resume();
await finished(idle, { cleanup: true });

const transformed = [];
const transform = new Transform({
  readableHighWaterMark: 1,
  writableHighWaterMark: 1,
  transform(chunk, encoding, callback) { process.nextTick(() => callback(null, Buffer.from(chunk.toString().toUpperCase()))); },
  flush(callback) { process.nextTick(() => callback(null, Buffer.from('!'))); },
});
const pass = new PassThrough();
check(pass instanceof Readable && pass instanceof Writable && pass instanceof Duplex && pass instanceof Transform, 'duplex brands');
await pipeline(Readable.from([Buffer.from('a'), Buffer.from('b')]), transform, pass, new Writable({ highWaterMark: 1, write(chunk, encoding, callback) { transformed.push(chunk.toString()); process.nextTick(callback); } }));
results.transform = transformed.join('');

const asyncValues = [];
async function* generate() { yield 4; yield Promise.resolve(5); }
await pipeline(Readable.from(generate()), new Writable({ objectMode: true, write(chunk, encoding, callback) { asyncValues.push(chunk); callback(); } }));
results.async = asyncValues;

let returned = false, cleanup = false;
const source = {
  [Symbol.asyncIterator]() { return this; },
  next() { return Promise.resolve({ value: Buffer.from('payload'), done: false }); },
  return() { returned = true; return Promise.resolve({ done: true }); },
};
const failure = new Error('sink identity');
let observed;
try {
  await pipeline(Readable.from(source), new Writable({
    write(chunk, encoding, callback) { callback(failure); },
    destroy(error, callback) { process.nextTick(() => { cleanup = true; callback(error); }); },
  }));
}
catch (error) { observed = error; }
check(observed === failure && returned && cleanup, 'pipeline must await real iterator/resource cleanup');
results.cleanup = [returned, cleanup];

for (const where of ['read', 'final', 'flush']) {
  const error = new Error(where + ' failure');
  const input = where === 'read' ? new Readable({ read() { this.destroy(error); } }) : Readable.from([Buffer.from('x')]);
  const middle = where === 'flush' ? new Transform({ transform(chunk, encoding, callback) { callback(null, chunk); }, flush(callback) { callback(error); } }) : new PassThrough();
  const output = new Writable({ write(chunk, encoding, callback) { callback(); }, final(callback) { callback(where === 'final' ? error : null); } });
  let caught;
  try { await pipeline(input, middle, output); } catch (failure) { caught = failure; }
  check(caught === error && input.destroyed && middle.destroyed && output.destroyed, 'pipeline ' + where + ' failure');
}
results.errorIdentities = true;

const premature = new Readable({ read() { this.destroy(); } });
const sink = new Writable({ write(chunk, encoding, callback) { callback(); } });
let prematureError;
try { await pipeline(premature, sink); } catch (error) { prematureError = error; }
check(prematureError && prematureError.code === 'ERR_STREAM_PREMATURE_CLOSE' && sink.destroyed, 'premature close');
results.premature = prematureError.code;

const callbackData = [];
const callbackSink = new Writable({ write(chunk, encoding, callback) { callbackData.push(chunk.toString()); callback(); } });
await new Promise((resolve, reject) => {
  const result = stream.pipeline(Readable.from([Buffer.from('callback')]), callbackSink, error => error ? reject(error) : resolve());
  check(result === callbackSink, 'callback pipeline returns destination');
});
results.callback = callbackData.join('');

const encoded = [];
const byteSink = Writable({ write(chunk, encoding, callback) { check(Buffer.isBuffer(chunk), 'binary chunks must be Buffers'); encoded.push([Buffer.from(chunk).toString('hex'), encoding]); callback(); } });
byteSink.write('hé');
byteSink.write(new Uint8Array([255, 0]));
byteSink.end('41', 'hex');
await finished(byteSink, { cleanup: true });
results.bytes = encoded;
console.log(JSON.stringify(results));
