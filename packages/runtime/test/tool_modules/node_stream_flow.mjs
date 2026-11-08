import { Readable, Transform, Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
const chunks = [];
const input = Readable.from([Buffer.from('a'), Buffer.from('b')]);
const upper = new Transform({ transform(chunk, encoding, callback) { callback(null, Buffer.from(chunk.toString().toUpperCase())); } });
const output = new Writable({ write(chunk, encoding, callback) { chunks.push(chunk.toString()); process.nextTick(callback); } });
await pipeline(input, upper, output);
if (chunks.join('') !== 'AB' || !output.writableFinished || !input.readableEnded) throw new Error('actual flow/completion missing');
console.log(JSON.stringify({ data: chunks.join(''), finished: output.writableFinished, ended: input.readableEnded }));
