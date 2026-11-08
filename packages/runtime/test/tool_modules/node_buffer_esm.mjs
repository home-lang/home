import buffer, { Buffer } from 'node:buffer';
import { createRequire } from 'node:module';
const requireHere = createRequire(import.meta.url);
if (buffer !== requireHere('buffer') || Buffer !== globalThis.Buffer || buffer.Buffer !== Buffer) throw new Error('ESM buffer identity');
const bytes = Buffer.from('bytes');
if (bytes.toString('hex') !== '6279746573') throw new Error('real buffer contents');
console.log('OK home-tool ESM Buffer identity');
