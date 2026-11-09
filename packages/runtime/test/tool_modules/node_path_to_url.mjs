import url, { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
const moduleRequire = createRequire(import.meta.url);
const vectors = moduleRequire('./node_path_to_url.expected.json');
const URLClass = globalThis.URL;
if (url !== moduleRequire('url') || url !== moduleRequire('node:url') || pathToFileURL !== url.pathToFileURL)
  throw new Error('URL module identity differs');
for (const item of vectors.cases) {
  const result = pathToFileURL(item.path);
  if (!(result instanceof URLClass) || Object.getPrototypeOf(result) !== URLClass.prototype)
    throw new Error('File conversion did not return the actual provider URL');
  for (const key of ['href', 'pathname', 'protocol', 'host', 'search', 'hash', 'origin']) {
    if (result[key] !== item[key])
      throw new Error('File URL field mismatch: ' + JSON.stringify({ path: item.path, key, actual: result[key], expected: item[key] }));
  }
  if (result.toString() !== item.href || result.toJSON() !== item.href)
    throw new Error('File URL serialization differs');
}
for (const units of [[0xd800], [0xdc00], [0xd800, 0x78, 0xdfff]]) {
  const input = '/tmp/' + String.fromCharCode(...units);
  const expected = units.length === 1 ? 'file:///tmp/%EF%BF%BD' : 'file:///tmp/%EF%BF%BDx%EF%BF%BD';
  if (pathToFileURL(input).href !== expected) throw new Error('Runtime surrogate replacement differs');
}
for (const item of vectors.errors) {
  let error;
  try { pathToFileURL(item.path); }
  catch (caught) { error = { name: caught.name, code: caught.code }; }
  if (JSON.stringify(error) !== JSON.stringify(item.error)) throw new Error('Invalid path accepted or wrong error');
}
for (const input of [undefined, Symbol('path'), function() {}]) {
  let rejected = false;
  try { pathToFileURL(input); }
  catch (error) { rejected = error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE'; }
  if (!rejected) throw new Error('Non-string path accepted');
}
if (process.cwd() !== import.meta.dirname) throw new Error('Run the relative-path witness in its module directory');
const cwdURL = new URLClass('./', import.meta.url).href;
for (const [input, expected] of [
  ['', cwdURL.endsWith('///') ? cwdURL : cwdURL.slice(0, -1)],
  ['.', cwdURL.endsWith('///') ? cwdURL : cwdURL.slice(0, -1)],
  ['child', cwdURL + 'child'],
  ['child/', cwdURL + 'child/'],
  ['child/../', cwdURL],
  ['../sibling', new URLClass('../sibling', import.meta.url).href],
]) {
  if (pathToFileURL(input).href !== expected) throw new Error('Relative path resolution differs: ' + input);
}
try {
  globalThis.URL = undefined;
  const retained = pathToFileURL('/tmp/retained');
  if (!(retained instanceof URLClass) || retained.href !== 'file:///tmp/retained' || retained.toString() !== retained.href)
    throw new Error('URL provider was replaced by user code');
}
finally { globalThis.URL = URLClass; }
console.log('OK Home provider-backed POSIX file URLs: 282 paths, 9 invalid paths, 6 relative paths, 3 runtime surrogate controls and retained constructor');
