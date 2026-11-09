import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
export const result = require('../interop_commonjs.cjs').value;
