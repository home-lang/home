import os, { platform } from 'node:os';
import alias from 'os';
import process from 'node:process';
import { createRequire } from 'node:module';
function check(value, message) { if (!value) throw new Error(message); }
const actual = process.platform;
check(os === alias && os.platform === platform && createRequire(process.argv[1])('os').platform === platform, 'module alias identity');
check(typeof platform === 'function' && platform() === actual && platform.call(null) === actual, 'actual native platform');
const original = Object.getOwnPropertyDescriptor(process, 'platform');
try {
  Object.defineProperty(process, 'platform', { value: 'caller-overridden' });
  check(platform() === 'caller-overridden', 'Node reads the current native process object property');
  const originalProcess = globalThis.process;
  try {
    globalThis.process = { platform: 'replacement-global' };
    check(platform() === 'caller-overridden', 'OS module must retain its original process object');
  }
  finally { globalThis.process = originalProcess; }
}
finally { Object.defineProperty(process, 'platform', original); }
check(platform() === actual, 'platform after restore');
console.log('OK native OS platform source, aliases and Node process-property semantics');
