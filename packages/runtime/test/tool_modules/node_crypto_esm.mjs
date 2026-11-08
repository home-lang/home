import crypto, { randomBytes } from 'crypto';
import { createRequire } from 'node:module';
const requireHere = createRequire(import.meta.url);
if (crypto !== requireHere('node:crypto') || randomBytes !== crypto.randomBytes) throw new Error('ESM crypto identity');
const bytes = randomBytes(24);
if (bytes.toString('hex').length !== 48) throw new Error('crypto Buffer transport');
console.log('OK home-tool ESM OS entropy');
