import events, { EventEmitter } from 'node:events';
import buffer, { Buffer } from 'node:buffer';
import fs, * as namespace from 'node:fs';
const _mod = 41;
function nested(__home_cjs_import_1_0) { return __home_cjs_import_1_0; }
if (events !== EventEmitter || buffer.Buffer !== Buffer || namespace.readFileSync !== fs.readFileSync || namespace.default !== fs) throw new Error('mixed import bindings or namespace missing');
if (nested(_mod) !== 41 || Buffer.from('a').toString('hex') !== '61') throw new Error('source binding captured');
console.log('OK mixed import bindings 42');
