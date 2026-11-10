// All 40 profile checks run on every oracle. Node/Bun differ on access
// return values and URL getter/toString side effects; retain those failures.
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import * as nodeURL from 'node:url';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
const NativeURL = globalThis.URL;
if (typeof NativeURL !== 'function') {
  const error = new Error('File URL filesystem profile requires a native URL implementation');
  error.code = 'ERR_HOME_UNSUPPORTED';
  throw error;
}
const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), 'home-url-fs-')));
const url = (name) => nodeURL.pathToFileURL(join(root, name));
const special = 'space # % + 🦎.bin';
const source = join(root, special);
const sourceURL = url(special);
const bytes = Buffer.from([0, 255, 128, 65, 0, 66]);
fs.writeFileSync(source, bytes);
let checks = 0;
const failures = [];
function assert(value, message) { if (!value) throw new Error(message); }
async function check(name, action) {
  checks++;
  try { await action(); } catch (error) { failures.push(name + ': ' + error.message); }
}
function code(error, expected) { assert(error && error.code === expected, 'expected ' + expected + ', got ' + (error && error.code)); }
async function rejects(action, expected) {
  let error;
  try { await action(); } catch (caught) { error = caught; }
  if (expected) code(error, expected);
  else assert(error instanceof TypeError, 'reject a receiver without native URL state');
}
try {
  await check('native URL module export', async () => {
    assert(nodeURL.URL === NativeURL && nodeURL.URLSearchParams === globalThis.URLSearchParams, 'export actual realm constructors');
  });
  await check('actual path URL preserves filename data', async () => {
    assert(sourceURL instanceof NativeURL && nodeURL.fileURLToPath(sourceURL) === source, 'decode UTF-8, spaces, percent, hash and plus once');
  });
  await check('sync binary read', async () => { assert(fs.readFileSync(sourceURL).equals(bytes), 'preserve every source byte'); });
  await check('promise binary read', async () => { assert((await fsp.readFile(sourceURL)).equals(bytes), 'preserve every promised source byte'); });
  await check('sync write URL', async () => { fs.writeFileSync(url('sync-write'), bytes); assert(fs.readFileSync(join(root, 'sync-write')).equals(bytes), 'write actual bytes'); });
  await check('promise write URL', async () => { await fsp.writeFile(url('promise-write'), bytes); assert(fs.readFileSync(join(root, 'promise-write')).equals(bytes), 'write actual bytes'); });
  await check('promise append URL', async () => { await fsp.writeFile(url('append'), 'a'); await fsp.appendFile(url('append'), 'b'); assert(fs.readFileSync(join(root, 'append'), 'utf8') === 'ab', 'append actual data'); });
  await check('sync stat and lstat URLs', async () => { assert(fs.statSync(sourceURL).size === bytes.length && fs.lstatSync(sourceURL).isFile(), 'stat real file'); });
  await check('promise stat URL', async () => { assert((await fsp.stat(sourceURL)).size === bytes.length, 'stat real file'); });
  await check('real chmod URL', async () => { await fsp.chmod(sourceURL, 0o640); assert((fs.statSync(source).mode & 0o777) === 0o640, 'change real file mode'); });
  await check('real access URL', async () => { assert(await fsp.access(sourceURL, fs.constants.R_OK) === undefined, 'check actual access'); });
  await check('exists URL', async () => { assert(fs.existsSync(sourceURL), 'observe actual source file'); });
  await check('missing exists URL', async () => { assert(!fs.existsSync(url('missing')), 'observe missing file'); });
  await check('missing read propagates native error', async () => { await rejects(() => fsp.readFile(url('missing')), 'ENOENT'); });
  await check('recursive mkdir URL', async () => { assert(await fsp.mkdir(url('parent/child'), { recursive: true }) === join(root, 'parent'), 'return actual first created path'); assert(fs.statSync(join(root, 'parent/child')).isDirectory(), 'create real nested directory'); });
  await check('sync copy URL pair', async () => { fs.cpSync(sourceURL, url('sync-copy')); assert(fs.readFileSync(join(root, 'sync-copy')).equals(bytes), 'copy actual bytes'); });
  await check('promise recursive copy URL pair', async () => { await fsp.mkdir(join(root, 'tree')); await fsp.writeFile(join(root, 'tree/file'), bytes); await fsp.cp(url('tree'), url('copied-tree'), { recursive: true }); assert(fs.readFileSync(join(root, 'copied-tree/file')).equals(bytes), 'copy actual tree'); });
  await check('rename URL pair', async () => { await fsp.writeFile(join(root, 'move-from'), bytes); await fsp.rename(url('move-from'), url('move-to')); assert(!fs.existsSync(join(root, 'move-from')) && fs.readFileSync(join(root, 'move-to')).equals(bytes), 'move real entry'); });
  await check('rm URL tree', async () => { await fsp.rm(url('copied-tree'), { recursive: true }); assert(!fs.existsSync(join(root, 'copied-tree')), 'delete actual tree'); });
  await check('rmdir URL', async () => { fs.mkdirSync(join(root, 'empty')); await fsp.rmdir(url('empty')); assert(!fs.existsSync(join(root, 'empty')), 'delete empty directory'); });
  await check('open URL and write actual descriptor', async () => { const fd = fs.openSync(url('descriptor'), 'w'); try { fs.writeFileSync(fd, bytes); } finally { fs.closeSync(fd); } assert(fs.readFileSync(join(root, 'descriptor')).equals(bytes), 'use actual descriptor'); });
  await check('readdir URL', async () => { assert((await fsp.readdir(nodeURL.pathToFileURL(root))).includes(special), 'list real UTF-8 name'); });
  await check('realpath URL', async () => { assert(await fsp.realpath(sourceURL) === source, 'resolve real file'); });
  await check('query and hash are URL syntax', async () => { assert(fs.readFileSync(new NativeURL(sourceURL.href + '?query#hash')).equals(bytes), 'do not append URL syntax to filename'); });
  await check('relative URL resolves actual file', async () => { const base = nodeURL.pathToFileURL(root + '/'); assert(fs.readFileSync(new NativeURL('./unused/../sync-write', base)).equals(bytes), 'normalize relative URL before filesystem operation'); });
  await check('non-file URL refused', async () => { await rejects(() => fsp.readFile(new NativeURL('https://example.com/file')), 'ERR_INVALID_URL_SCHEME'); });
  await check('encoded slash refused', async () => { await rejects(() => fsp.readFile(new NativeURL('file://' + root + '/a%2Fb')), 'ERR_INVALID_FILE_URL_PATH'); });
  await check('remote file host refused', async () => { await rejects(() => fsp.readFile(new NativeURL('file://remote.invalid/file')), 'ERR_INVALID_FILE_URL_HOST'); });
  await check('encoded NUL cannot reach filesystem', async () => { await rejects(() => fsp.readFile(new NativeURL('file://' + root + '/nul%00')), 'ERR_INVALID_ARG_VALUE'); });
  await check('pure URL conversion retains NUL', async () => { assert(nodeURL.fileURLToPath(new NativeURL('file:///nul%00')) === '/nul\0', 'conversion and filesystem validation have distinct semantics'); });
  await check('href duck object is refused without reading it', async () => { let reads = 0; await rejects(() => fsp.readFile({ get href() { reads++; return sourceURL.href; } })); assert(reads === 0, 'do not invoke arbitrary href getter'); });
  await check('prototype-only object refused', async () => { await rejects(() => fsp.readFile(Object.create(NativeURL.prototype))); });
  await check('copied own URL fields refused', async () => { const copied = Object.create(NativeURL.prototype); Object.defineProperties(copied, Object.getOwnPropertyDescriptors(sourceURL)); await rejects(() => fsp.readFile(copied)); });
  await check('URL proxy is not its target', async () => { await rejects(() => fsp.readFile(new Proxy(sourceURL, {}))); });
  await check('genuine URL does not use arbitrary toString', async () => { const real = url(special); real.toString = () => { throw new Error('do not call overridden toString'); }; assert(fs.readFileSync(real).equals(bytes), 'read intrinsic URL state'); });
  await check('retain constructor after global replacement', async () => { const saved = globalThis.URL; try { globalThis.URL = function() { throw new Error('replacement URL'); }; assert(fs.readFileSync(sourceURL).equals(bytes), 'retain intrinsic constructor'); assert(nodeURL.fileURLToPath(sourceURL) === source, 'retain converter'); } finally { globalThis.URL = saved; } });
  await check('retain apply after Reflect replacement', async () => { const saved = Reflect.apply; try { Reflect.apply = () => { throw new Error('replacement apply'); }; assert(fs.readFileSync(sourceURL).equals(bytes), 'retain intrinsic apply'); } finally { Reflect.apply = saved; } });
  await check('file URL string stays a literal path', async () => { await rejects(() => fsp.readFile(sourceURL.href), 'ENOENT'); assert(fs.readFileSync(source).equals(bytes), 'do not reinterpret string filenames'); });
  await check('invalid scheme exists returns false', async () => { assert(!fs.existsSync(new NativeURL('https://example.com/file')), 'invalid file URL cannot exist'); });
  await check('callback stat URL', async () => { const stat = await new Promise((resolve, reject) => fs.stat(sourceURL, (error, value) => error ? reject(error) : resolve(value))); assert(stat.size === bytes.length, 'native callback stat'); });
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
if (checks !== 40) throw new Error('File URL filesystem inventory changed');
if (failures.length) throw new Error('NODE FILE URL FS ' + checks + ' checks; failures: ' + failures.join('; '));
console.log('NODE FILE URL FS ' + checks + ' CHECKS OK');
