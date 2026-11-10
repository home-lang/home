import fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
const NativeURL = globalThis.URL;
if (typeof NativeURL !== 'function') throw new Error('Native URL createRequire profile requires a provider URL implementation');
const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), 'home-module-url-')));
const child = join(root, 'space # % 🦎');
fs.mkdirSync(child);
fs.writeFileSync(join(root, 'package.json'), JSON.stringify({ type: 'commonjs', imports: { '#local': './dependency.cjs' } }));
fs.writeFileSync(join(child, 'package.json'), JSON.stringify({ type: 'commonjs', imports: { '#local': './dependency.cjs' } }));
fs.writeFileSync(join(root, 'dependency.cjs'), 'module.exports = { value: 42 };\n');
fs.writeFileSync(join(child, 'dependency.cjs'), 'module.exports = { value: 84 };\n');
fs.writeFileSync(join(root, 'data.json'), JSON.stringify({ text: 'espaço 🦎' }));
fs.writeFileSync(join(root, 'invalid.cjs'), 'module.exports = ( ;\n');
const anchor = pathToFileURL(join(root, 'not-created.cjs'));
const childAnchor = pathToFileURL(join(child, 'not-created.cjs'));
let checks = 0;
const failures = [];
function assert(value, message) { if (!value) throw new Error(message); }
function check(name, action) {
  checks++;
  try { action(); } catch (error) { failures.push(name + ': ' + error.message); }
}
function rejects(value, expected) {
  let error;
  try { createRequire(value); } catch (caught) { error = caught; }
  assert(error instanceof TypeError, 'invalid referrer must throw TypeError');
  if (expected) assert(error.code === expected, 'expected ' + expected + ', got ' + error.code);
}
try {
  check('actual relative CommonJS dependency', () => { assert(createRequire(anchor)('./dependency.cjs').value === 42, 'execute real written dependency'); });
  check('actual relative resolution', () => { assert(createRequire(anchor).resolve('./dependency.cjs') === join(root, 'dependency.cjs'), 'resolve actual canonical file'); });
  check('referrer filename need not exist', () => { assert(!fs.existsSync(join(root, 'not-created.cjs')) && createRequire(anchor)('./dependency.cjs').value === 42, 'anchor without fabricating referrer file'); });
  check('native and string URL share module identity', () => { assert(createRequire(anchor)('./dependency.cjs') === createRequire(anchor.href)('./dependency.cjs'), 'reuse actual cache entry'); });
  check('native URL and absolute path share module identity', () => { assert(createRequire(anchor)('./dependency.cjs') === createRequire(join(root, 'not-created.cjs'))('./dependency.cjs'), 'reuse actual cache entry'); });
  check('JSON from native URL scope', () => { assert(createRequire(anchor)('./data.json').text === 'espaço 🦎', 'load actual JSON'); });
  check('builtin module identity', () => { assert(createRequire(anchor)('node:fs') === fs && createRequire(anchor)('fs') === fs, 'keep real builtin identity'); });
  check('builtin resolution', () => { assert(createRequire(anchor).resolve('node:fs') === 'node:fs', 'preserve builtin prefix'); });
  check('root package imports', () => { assert(createRequire(anchor)('#local').value === 42, 'read actual root package scope'); });
  check('UTF-8 escaped child scope', () => { assert(createRequire(childAnchor)('./dependency.cjs').value === 84, 'decode percent, spaces, hash and UTF-8 once'); });
  check('child package imports', () => { assert(createRequire(childAnchor)('#local').value === 84, 'read actual child package scope'); });
  check('distinct scopes retain distinct modules', () => { assert(createRequire(anchor)('./dependency.cjs') !== createRequire(childAnchor)('./dependency.cjs'), 'do not ignore referrer'); });
  check('cross-scope resolution shares actual module', () => { assert(createRequire(anchor)('./space # % 🦎/dependency.cjs') === createRequire(childAnchor)('./dependency.cjs'), 'keep canonical cache identity'); });
  check('directory URL referrer', () => { assert(createRequire(pathToFileURL(child + '/'))('./dependency.cjs').value === 84, 'preserve trailing slash directory'); });
  check('query and hash ignored as URL syntax', () => { assert(createRequire(new NativeURL(childAnchor.href + '?query#hash'))('./dependency.cjs').value === 84, 'do not interpret URL suffix as filename'); });
  check('relative URL resolution', () => { assert(createRequire(new NativeURL('./unused/../not-created.cjs', pathToFileURL(child + '/')))('./dependency.cjs').value === 84, 'use normalized actual directory'); });
  check('localhost file URL', () => { assert(createRequire(new NativeURL(anchor.href.replace('file:///', 'file://localhost/')))('./dependency.cjs').value === 42, 'accept local file host'); });
  check('factory snapshots mutable URL referrer', () => { const mutable = new NativeURL(anchor.href); const require = createRequire(mutable); mutable.href = childAnchor.href; assert(require('./dependency.cjs').value === 42 && createRequire(mutable)('./dependency.cjs').value === 84, 'capture the path at factory creation'); });
  check('resolve does not parse invalid target', () => { assert(createRequire(anchor).resolve('./invalid.cjs') === join(root, 'invalid.cjs'), 'resolve real invalid-source file without evaluating it'); });
  check('non-file URL rejected', () => { rejects(new NativeURL('https://example.com/file.cjs'), 'ERR_INVALID_ARG_VALUE'); });
  check('remote file host rejected', () => { rejects(new NativeURL('file://remote.invalid/file.cjs'), 'ERR_INVALID_ARG_VALUE'); });
  check('encoded separator rejected', () => { rejects(new NativeURL('file://' + root + '/base%2Fname.cjs'), 'ERR_INVALID_ARG_VALUE'); });
  check('plain object rejected', () => { rejects({}); });
  check('prototype-only URL rejected', () => { rejects(Object.create(NativeURL.prototype)); });
  check('copied URL fields rejected', () => { const copied = Object.create(NativeURL.prototype); Object.defineProperties(copied, Object.getOwnPropertyDescriptors(anchor)); rejects(copied); });
  check('URL proxy rejected', () => { rejects(new Proxy(anchor, {})); });
  check('module ID still requires a string', () => { let error; try { createRequire(anchor)(42); } catch (caught) { error = caught; } assert(error instanceof TypeError, 'do not coerce arbitrary module IDs'); });
} finally { fs.rmSync(root, { recursive: true, force: true }); }
if (checks !== 27) throw new Error('Native URL createRequire inventory changed');
if (failures.length) throw new Error('NODE MODULE URL ' + checks + ' checks; failures: ' + failures.join('; '));
console.log('NODE MODULE URL ' + checks + ' CHECKS OK');
