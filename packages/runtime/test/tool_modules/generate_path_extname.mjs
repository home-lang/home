import { extname } from 'node:path/posix';
import fs from 'node:fs';
const paths = new Set(['', '/', '//', '.', '..', '...', '/..', '/../', '/a/..', 'index.html', 'index.coffee.md', 'index.', '.index', '.index.md', 'dir.ext/file', 'dir.ext/.hidden', 'dir.ext/.hidden.suffix///', 'C:\\dir.ext\\file', 'C:\\dir\\file.ext', 'file:///tmp/a.txt', 'a\0b.txt', '航/🧪.é', 'a/\ud800.x', 'a/\udc00.x']);
let level = [''];
for (let size = 1; size <= 5; size++) {
  level = level.flatMap(prefix => ['.', 'a', '/'].map(character => prefix + character));
  for (const value of level) paths.add(value);
}
for (let code = 0; code < 256; code++) paths.add('dir.ext/name' + String.fromCharCode(code) + '.suffix/');
const cases = [...paths].map(path => [path, extname(path)]);
const errors = [null, 1, true, {}, [], { toString: 'path' }].map(path => {
  try { extname(path); throw new Error('accepted invalid path'); }
  catch (error) { return { path, error: { name: error.name, code: error.code } }; }
});
fs.writeFileSync(process.argv[2], JSON.stringify({ node: process.version, cases, errors }, null, 2) + '\n');
console.log(`Generated ${cases.length} POSIX extname vectors and ${errors.length} invalid-path controls using ${process.version}`);
