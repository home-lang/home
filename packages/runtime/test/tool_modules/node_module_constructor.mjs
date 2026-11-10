import Module, * as namespace from 'node:module';
import fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), 'home-module-constructor-')));
const originalCache = Module._cache;
const originalPrototype = Module.prototype && Module.prototype.require;
const originalResolve = Module._resolveFilename;
const require = Module.createRequire(join(root, 'anchor.cjs'));
let checks = 0;
const failures = [];
function assert(value, message) { if (!value) throw new Error(message); }
function check(name, action) { checks++; try { action(); } catch (error) { failures.push(name + ': ' + error.message); } }
async function checkAsync(name, action) { checks++; try { await action(); } catch (error) { failures.push(name + ': ' + error.message); } }
function file(name, source) { fs.writeFileSync(join(root, name), source); }
function rejects(action, code) { let error; try { action(); } catch (caught) { error = caught; } assert(error, 'must throw'); if (code) assert(error.code === code, 'expected ' + code + ', got ' + error.code); return error; }
file('alpha.cjs', 'exports.value = 42; exports.module = module; exports.topThis = this === exports; exports.ownRequire = Object.hasOwn(module,"require"); exports.loadedDuring = module.loaded;');
file('beta.cjs', 'exports.value = 84; exports.module = module;');
file('entry.cjs', 'exports.module = module; exports.child = require("./alpha.cjs"); exports.later = () => require("./beta.cjs");');
file('cycle-a.cjs', 'exports.value = "partial-a"; exports.module = module; exports.b = require("./cycle-b.cjs"); exports.value = "finished-a";');
file('cycle-b.cjs', 'exports.module = module; const a = require("./cycle-a.cjs"); exports.seen = a.value; exports.a = a;');
file('throws.cjs', 'throw new Error("real-cjs-failure");');
file('reload.cjs', 'globalThis.__moduleContractLoads = (globalThis.__moduleContractLoads || 0) + 1; module.exports = { count: globalThis.__moduleContractLoads, module };');
file('invalid.cjs', 'module.exports = ( ;');
file('data.json', '{"value":123}');
file('sync.mjs', 'export const value = 321;');
file('async.mjs', 'await Promise.resolve(); export const value = 654;');
file('throws.mjs', 'globalThis.__moduleContractEsmLoads = (globalThis.__moduleContractEsmLoads || 0) + 1; throw new Error("real-esm-failure");');
try {
  check('default constructor and aliases', () => { assert(typeof Module === 'function' && Module.Module === Module && namespace.Module === Module, 'actual constructor aliases'); });
  check('constructor creates distinct exports', () => { const a = new Module('a'), b = new Module('b'); assert(a.exports !== b.exports && Object.keys(a.exports).length === 0, 'fresh exports objects'); });
  check('constructor initial state', () => { const a = new Module('directory/id'); assert(a.id === 'directory/id' && a.path === 'directory' && a.filename === null && a.loaded === false && a.children.length === 0 && a.parent === undefined, 'constructor state'); });
  check('constructor parent children', () => { const p = new Module('parent'), a = new Module('child', p); assert(a.parent === p && p.children[0] === a, 'actual parent linkage'); });
  check('constructor parent setter', () => { const a = new Module('child'), p = new Module('parent'); a.parent = p; assert(a.parent === p && p.children.length === 0, 'setter does not invent load edges'); });
  check('constructor call requires receiver', () => { assert(rejects(() => Module('bad')) instanceof TypeError, 'no implicit global instance'); });
  check('constructor validates id', () => { assert(rejects(() => new Module(42)) instanceof TypeError, 'id must be pathname string'); });
  check('prototype require is real', () => { assert(typeof Module.prototype.require === 'function' && new Module('probe').require === Module.prototype.require, 'shared prototype'); });
  check('real dependency executes', () => { assert(require('./alpha.cjs').value === 42, 'read actual written CJS'); });
  check('loaded modules are Module instances', () => { assert(require('./alpha.cjs').module instanceof Module, 'cache contains actual instances'); });
  check('loaded modules inherit require', () => { const a = require('./alpha.cjs'); assert(!a.ownRequire && a.module.require === Module.prototype.require, 'no own bypass around prototype'); });
  check('CommonJS top-level receiver', () => { assert(require('./alpha.cjs').topThis, 'CJS this is exports'); });
  check('loaded state transition', () => { const a = require('./alpha.cjs'); assert(a.loadedDuring === false && a.module.loaded === true, 'loaded after evaluation'); });
  check('module filename path id', () => { const m = require('./alpha.cjs').module; assert(m.filename === join(root, 'alpha.cjs') && m.path === root && m.id === m.filename, 'canonical filename'); });
  check('real shared cache identity', () => { assert(Module._cache === require.cache && require.cache[require.resolve('./alpha.cjs')] === require('./alpha.cjs').module, 'same actual cache'); });
  check('parent and children from actual load', () => { const e = require('./entry.cjs'); assert(e.module.children.includes(e.child.module), 'record dependency edge'); });
  check('cached first parent remains', () => { const a = require('./alpha.cjs').module; const p = a.parent; require('./entry.cjs'); assert(a.parent === p, 'keep first parent'); });
  check('cached children have no duplicates', () => { const e = require('./entry.cjs'); e.later(); e.later(); const b = require('./beta.cjs').module; assert(e.module.children.filter(c => c === b).length === 1, 'deduplicate actual cache hits'); });
  check('manually anchored constructor require', () => { const m = new Module('manual'); m.filename = join(root, 'manual.cjs'); assert(m.require('./beta.cjs').value === 84, 'real anchored load'); });
  check('module-scope require observes own method', () => { const e = require('./entry.cjs'); const old = e.module.require; const alpha = require('./alpha.cjs'); try { e.module.require = function(id) { return id === './beta.cjs' ? alpha : old.call(this, id); }; assert(e.later() === alpha, 'live method dispatch'); } finally { delete e.module.require; } });
  check('prototype hook sees createRequire and nested require', () => { const old = Module.prototype.require; const hits = []; file('hook-entry.cjs', 'module.exports = require("./beta.cjs");'); try { Module.prototype.require = function(id) { hits.push([id, this.filename]); return old.apply(this, arguments); }; assert(require('./hook-entry.cjs').value === 84 && hits.some(h => h[0] === './hook-entry.cjs') && hits.some(h => h[0] === './beta.cjs' && h[1] === join(root, 'hook-entry.cjs')), 'actual hook and receiver'); } finally { Module.prototype.require = old; } });
  check('prototype hook sees cached require', () => { const old = Module.prototype.require; let hits = 0; try { Module.prototype.require = function(id) { hits++; return old.call(this, id); }; require('./alpha.cjs'); assert(hits === 1, 'cached load still calls require hook'); } finally { Module.prototype.require = old; } });
  check('prototype hook uses real Module receiver', () => { const old = Module.prototype.require; let receiver; try { Module.prototype.require = function(id) { receiver = this; return old.call(this, id); }; require('./alpha.cjs'); assert(receiver instanceof Module && receiver.filename === join(root, 'anchor.cjs'), 'synthetic anchored Module'); } finally { Module.prototype.require = old; } });
  check('live resolution hook aliases real source', () => { const old = Module._resolveFilename; assert(typeof old === 'function', 'real filename resolver'); try { Module._resolveFilename = function(id, parent, main, options) { return old.call(this, id === 'contract-alias' ? './beta.cjs' : id, parent, main, options); }; assert(require('contract-alias').value === 84 && require.resolve('contract-alias') === join(root, 'beta.cjs'), 'load and resolve use actual hook'); } finally { Module._resolveFilename = old; } });
  check('direct filename resolution', () => { const m = new Module('probe'); m.filename = join(root, 'anchor.cjs'); assert(Module._resolveFilename('./alpha.cjs', m, false) === join(root, 'alpha.cjs'), 'native resolution from actual anchor'); });
  check('builtin alias identity', () => { assert(require('module') === Module && require('node:module') === Module && require('node:fs') === fs, 'real builtin aliases'); });
  check('builtin resolution keeps prefix', () => { assert(Module._resolveFilename('node:fs') === 'node:fs' && require.resolve('fs') === 'fs', 'builtin filename'); });
  check('cache exports mutation', () => { const key = require.resolve('./beta.cjs'), m = require.cache[key], old = m.exports; try { m.exports = { value: 987 }; assert(require('./beta.cjs').value === 987, 'read live cache exports'); } finally { m.exports = old; } });
  check('cache entry replacement', () => { const key = require.resolve('./beta.cjs'), old = require.cache[key], replacement = { exports: { value: 876 }, loaded: true }; try { require.cache[key] = replacement; assert(require('./beta.cjs') === replacement.exports, 'replacement is authoritative'); } finally { require.cache[key] = old; } });
  check('cache deletion reexecutes real file', () => { const first = require('./reload.cjs'); delete require.cache[require.resolve('./reload.cjs')]; const second = require('./reload.cjs'); assert(second.count === first.count + 1 && second.module !== first.module, 'actual source rerun'); });
  check('cache replacement changes loader without changing old function cache', () => { const saved = Module._cache; const prior = require('./reload.cjs'); try { Module._cache = Object.create(null); const fresh = Module.createRequire(join(root, 'new-anchor.cjs')); assert(fresh.cache === Module._cache && require.cache === saved && fresh('./reload.cjs').count === prior.count + 1, 'real active cache and old reference'); } finally { Module._cache = saved; } assert(require('./reload.cjs') === prior, 'restored actual cache entry'); });
  check('cycle exposes actual partial exports', () => { const a = require('./cycle-a.cjs'); assert(a.value === 'finished-a' && a.b.seen === 'partial-a' && a.b.a === a && a.module.children.includes(a.b.module) && a.b.module.children.includes(a.module), 'cycle and dependency edges'); });
  check('failed CJS evicts cache and failed child', () => { const key = require.resolve('./throws.cjs'); const old = Module.prototype.require; let parent; try { Module.prototype.require = function(id) { if (id === './throws.cjs') parent = this; return old.apply(this, arguments); }; rejects(() => require('./throws.cjs')); assert(!require.cache[key] && parent.children.every(child => child.filename !== key), 'evict failed module and child edge'); fs.writeFileSync(key, 'module.exports = { value: 765 };'); assert(require('./throws.cjs').value === 765 && parent.children.filter(child => child.filename === key).length === 1, 'retry reads new source and records one edge'); } finally { Module.prototype.require = old; } });
  check('JSON cache contains actual Module', () => { assert(require('./data.json').value === 123 && require.cache[require.resolve('./data.json')] instanceof Module, 'actual JSON loader'); });
  check('resolve does not parse target', () => { const key = require.resolve('./invalid.cjs'); assert(key === join(root, 'invalid.cjs') && !require.cache[key], 'no evaluation during resolution'); });
  check('invalid numeric request', () => { assert(rejects(() => require(42), 'ERR_INVALID_ARG_TYPE') instanceof TypeError, 'reject rather than coerce'); });
  check('empty request', () => { assert(rejects(() => require(''), 'ERR_INVALID_ARG_VALUE') instanceof TypeError, 'reject empty string'); });
  check('missing request preserves code', () => { rejects(() => require('./not-created.cjs'), 'MODULE_NOT_FOUND'); });
  check('synchronous ESM still loads', () => { assert(require('./sync.mjs').value === 321, 'real sync ESM'); });
  check('failed ESM remains failed', () => { const a = rejects(() => require('./throws.mjs')); const b = rejects(() => require('./throws.mjs')); assert(a === b && globalThis.__moduleContractEsmLoads === 1, 'never return partial exports after ESM error'); });
  check('async require rejects before execution', () => { rejects(() => require('./async.mjs'), 'ERR_REQUIRE_ASYNC_MODULE'); });
  await checkAsync('async require still rejects after genuine import', async () => { const url = 'file://' + join(root, 'async.mjs').split('/').map(encodeURIComponent).join('/'); const m = await import(url); assert(m.value === 654, 'genuine async import'); rejects(() => require('./async.mjs'), 'ERR_REQUIRE_ASYNC_MODULE'); });
} finally {
  if (Module.prototype && originalPrototype) Module.prototype.require = originalPrototype;
  if (originalResolve) Module._resolveFilename = originalResolve;
  if (originalCache) Module._cache = originalCache;
  delete globalThis.__moduleContractLoads;
  delete globalThis.__moduleContractEsmLoads;
  fs.rmSync(root, { recursive: true, force: true });
}
console.log('NODE MODULE CONSTRUCTOR RESULTS', JSON.stringify({ checks: checks, passed: checks - failures.length, failures: failures }));
if (checks !== 42) throw new Error('Module constructor inventory changed: ' + checks);
if (failures.length) throw new Error('NODE MODULE CONSTRUCTOR ' + checks + ' checks; failures: ' + failures.join('; '));
console.log('NODE MODULE CONSTRUCTOR ' + checks + ' CHECKS OK');
