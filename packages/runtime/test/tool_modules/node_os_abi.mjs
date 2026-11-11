import os, { arch, endianness } from 'node:os';
import { createRequire } from 'node:module';
const requireHere = createRequire(import.meta.url);
const initial = { arch: arch(), endianness: endianness() };
let checks = 0;
function check(value, label) { if (!value) throw new Error(label); checks++; }
check(os === requireHere('os') && os === requireHere('node:os') && arch === os.arch && endianness === os.endianness && arch.length === 0 && endianness.length === 0, 'module aliases and arity');
const memory = new Uint8Array(new Uint16Array([0x0102]).buffer);
check(typeof initial.arch === 'string' && initial.arch === process.arch && initial.endianness === (memory[0] === 2 ? 'LE' : 'BE'), 'native architecture and memory byte order');
const archDescriptor = Object.getOwnPropertyDescriptor(process, 'arch');
const saved16 = globalThis.Uint16Array;
const saved8 = globalThis.Uint8Array;
try {
  const sentinel = new Error('arch getter witness');
  Object.defineProperty(process, 'arch', { configurable: true, get() { throw sentinel; } });
  let caught; try { arch(); } catch (error) { caught = error; }
  Object.defineProperty(process, 'arch', { configurable: true, value: 'user-visible-field' });
  check(caught === sentinel && arch() === 'user-visible-field', 'Node live process architecture field and getter failure');
  globalThis.Uint16Array = function() { throw new Error('replaceable JS constructor used'); };
  globalThis.Uint8Array = function() { throw new Error('replaceable JS constructor used'); };
  check(endianness() === initial.endianness && typeof globalThis.__home_tool_endianness === 'undefined', 'compiled endian is independent of public constructors and architecture field');
} finally {
  Object.defineProperty(process, 'arch', archDescriptor);
  globalThis.Uint16Array = saved16;
  globalThis.Uint8Array = saved8;
}
const coercion = { toString() { throw new Error('unexpected argument coercion'); }, valueOf() { throw new Error('unexpected argument coercion'); } };
check(arch.call(null, coercion) === initial.arch && endianness.call(null, coercion) === initial.endianness, 'borrowed calls ignore arguments');
if (checks !== 5) throw new Error('wrong ABI denominator');
console.log('NODE OS ABI RESULTS ' + JSON.stringify({ checks, passed: checks, ...initial }));
console.log('NODE OS ABI 5 CHECKS OK');
