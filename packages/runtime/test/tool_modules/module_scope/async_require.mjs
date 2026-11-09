import { createRequire } from 'node:module';
await Promise.resolve();
const require = createRequire(import.meta.url);
export const result = require('../interop_commonjs.cjs').value + 1;
