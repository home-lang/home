import { Readable, Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
const failure = new Error('actual sink failure');
const input = Readable.from([Buffer.from('payload')]);
const output = new Writable({ write(chunk, encoding, callback) { callback(failure); } });
let observed;
try { await pipeline(input, output); } catch (error) { observed = error; }
if (observed !== failure || !input.destroyed || !output.destroyed) throw new Error('pipeline error identity or cleanup failed');
console.log('OK actual pipeline error identity and cleanup');
