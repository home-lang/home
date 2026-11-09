const fromParent = require('..');
const fromDot = require('.');
if (fromParent.value !== 17 || fromParent !== require('../lib/main.cjs')) throw new Error('parent directory main or cache');
if (fromDot.value !== 42 || fromDot !== require('./index.js')) throw new Error('current directory index or cache');
if (require.resolve('..') !== require.resolve('../lib/main.cjs') || require.resolve('.') !== require.resolve('./index.js')) throw new Error('directory resolve');
const anchored = require('node:module').createRequire(__dirname + '/not-created.cjs');
if (anchored('..') !== fromParent || anchored('.') !== fromDot || anchored.resolve('..') !== require.resolve('..')) throw new Error('anchored directory resolution');
require('../index-only/check.cjs');
if (globalThis.directoryMainLoads !== 1) throw new Error('main executed more than once');
for (const invalid of ['...', '..not-a-path']) { let failed = false; try { require(invalid); } catch { failed = true; } if (!failed) throw new Error('invalid package became a relative path'); }
console.log('OK CommonJS dot directories, main, index, resolve, cache and createRequire');
