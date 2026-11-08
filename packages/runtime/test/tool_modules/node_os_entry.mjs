import os, { homedir } from 'node:os';
import { createRequire } from 'node:module';
const requireHere = createRequire(import.meta.url);
if (os !== requireHere('os') || os !== requireHere('node:os') || os.homedir !== homedir) throw new Error('os module identity');
const hadHome = Object.prototype.hasOwnProperty.call(process.env, 'HOME');
const saved = process.env.HOME;
try {
  delete process.env.HOME;
  const nativeHome = homedir();
  if (typeof nativeHome !== 'string' || !nativeHome.startsWith('/')) throw new Error('native account home');
  for (const value of ['/tmp/home-tool-home override', '']) {
    process.env.HOME = value;
    if (homedir() !== value) throw new Error('HOME override');
  }
  delete process.env.HOME;
  if (homedir() !== nativeHome) throw new Error('native home after deleting HOME');
} finally {
  if (hadHome) process.env.HOME = saved;
  else delete process.env.HOME;
}
console.log('OK home-tool POSIX home directory');
