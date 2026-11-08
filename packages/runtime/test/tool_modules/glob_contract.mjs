import { Glob } from 'bun';
if (Glob !== Bun.Glob || require('bun').Glob !== Glob) throw new Error('Glob identity differs');
const root = import.meta.dir + '/glob_files';
const files = ['plain', 'readme.md', 'src/a.ts', 'src/a.tsx', 'src/nested/c.md', '😀.md'];
const markdown = ['readme.md', 'src/nested/c.md', '😀.md'];
const cases = [
  ['**/*', {}, files],
  ['**/*.md', {}, markdown],
  ['*.md', {}, ['readme.md', '😀.md']],
  ['**/*.md', { dot: true }, ['.hidden.md', '.secret/x.md', ...markdown]],
  ['**/*', { onlyFiles: false }, ['alias.md', 'broken.md', 'empty', 'linked', 'plain', 'readme.md', 'src', 'src/a.ts', 'src/a.tsx', 'src/cycle', 'src/nested', 'src/nested/c.md', '😀.md']],
  ['**/*.md', { throwErrorOnBrokenSymlink: true }, markdown],
  ['.*', {}, ['.hidden.md']],
  ['.secret/*.md', {}, ['.secret/x.md']],
  ['./*.md', {}, ['./readme.md', './😀.md']],
  ['**/*.{ts,tsx}', {}, ['src/a.ts', 'src/a.tsx']],
  ['**/*.md', { absolute: true }, markdown.map(path => root + '/' + path)],
];
function equal(actual, expected) {
  if (JSON.stringify(actual.slice().sort()) !== JSON.stringify(expected.slice().sort())) throw new Error('Glob scan differs: ' + JSON.stringify(actual));
}
for (const [pattern, options, expected] of cases) {
  const glob = new Glob(pattern);
  equal(Array.from(glob.scanSync({ cwd: root, ...options })), expected);
  const asynchronous = [];
  for await (const path of glob.scan({ cwd: root, ...options })) asynchronous.push(path);
  equal(asynchronous, expected);
}
const relativeRoot = root.startsWith(process.cwd() + '/') ? root.slice(process.cwd().length + 1) : root;
equal(Array.from(new Glob('**/*.md').scanSync({ cwd: relativeRoot, absolute: true })), markdown.map(path => root + '/' + path));
const stringRoot = [];
for await (const path of new Glob('**/*.md').scan(root)) stringRoot.push(path);
equal(stringRoot, markdown);
equal(Array.from(new Glob('**/*.md').scanSync(root)), markdown);
for (const [pattern, path, expected] of [['**/*.md', 'src/doc.md', true], ['*.ts', 'src/a.ts', false], ['?.md', '😀.md', true], ['*.md', '.hidden.md', true], ['!*.md', 'value.ts', true], ['[ab].ts', 'a.ts', true]]) {
  if (new Glob(pattern).match(path) !== expected) throw new Error('Glob match differs: ' + pattern);
}
for (const run of [() => new Glob(42), () => new Glob('*').match(42), () => Array.from(new Glob('*').scanSync({ cwd: 42 }))]) {
  let failed = false;
  try { run(); } catch { failed = true; }
  if (!failed) throw new Error('Invalid Glob argument accepted');
}
for (const asynchronous of [false, true]) {
  let failure;
  try {
    const glob = new Glob('**/*');
    if (asynchronous) { for await (const path of glob.scan(root + '/not-created')) throw new Error('missing root yielded ' + path); }
    else Array.from(glob.scanSync(root + '/not-created'));
  } catch (error) { failure = error; }
  if (!failure || failure.code !== 'ENOENT') throw new Error('Missing root did not propagate ENOENT');
}
console.log('OK actual filesystem glob sync async options and matching');
