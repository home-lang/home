import { Readable, Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
const sink = new Writable({
  write() { console.log('waiting for actual write acknowledgment'); },
});
await pipeline(Readable.from([Buffer.from('pending')]), sink);
throw new Error('pipeline fabricated completion without write acknowledgment');
