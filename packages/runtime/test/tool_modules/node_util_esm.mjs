import util, { stripVTControlCharacters } from 'node:util';
import { createRequire } from 'node:module';
const requireHere = createRequire(import.meta.url);
if (util !== requireHere('util') || stripVTControlCharacters !== util.stripVTControlCharacters) throw new Error('ESM util identity');
if (stripVTControlCharacters('\x1b[31mred\x1b[0m') !== 'red') throw new Error('SGR bytes not stripped');
console.log('OK home-tool ESM VT controls');
