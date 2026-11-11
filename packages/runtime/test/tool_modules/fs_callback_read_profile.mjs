import fs from 'node:fs';
const root = process.argv[2], failures = [];
const attempts = [
  () => fs.readFile(root, { signal: {} }, () => failures.push('signal callback ran')),
  () => fs.readFile(root, 'latin1', () => failures.push('encoding callback ran')),
  () => fs.readFile(7, () => failures.push('descriptor callback ran')),
  () => fs.readdir(root, { recursive: true }, () => failures.push('recursive callback ran')),
  () => fs.readdir(root, 'buffer', () => failures.push('byte names callback ran')),
];
for (const attempt of attempts) {
  let refused = false;
  try { attempt(); } catch (e) { refused = e.code === 'ERR_HOME_UNSUPPORTED'; }
  if (!refused) failures.push('unsupported profile was accepted');
}
let encodingReads = 0, flagReads = 0;
await new Promise((resolve, reject) => fs.readFile(root + '/text-☃.txt', { get encoding() { encodingReads++; return 'utf8'; }, get flag() { flagReads++; return 'r'; } }, (error, value) => {
  if (error) { reject(error); return; }
  if (encodingReads !== 1 || flagReads !== 1 || value !== 'real UTF8 ☃\0line\n') failures.push('option snapshot was not once-only');
  resolve();
}));
console.log('HOME FS CALLBACK PROFILE RESULTS ' + JSON.stringify({ groups: attempts.length + 1, passed: attempts.length + 1 - failures.length, failures }));
if (failures.length) throw new Error('Filesystem profile refusal failed');
console.log('HOME FS CALLBACK PROFILE 5 REFUSALS AND OPTION SNAPSHOT OK');
