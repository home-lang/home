import fs, { readdirSync } from 'node:fs';
import alias from 'fs';
import promises from 'node:fs/promises';

function check(value, message) { if (!value) throw new Error(message); }
const root = process.argv[2];
check(fs === alias && fs.readdirSync === readdirSync && fs.promises === promises, 'filesystem aliases');
const expected = ['broken-link', 'directory-link', 'fifo', 'file-link', 'nested', 'plain.txt', 'socket', 'space 🟢.txt'];
check(JSON.stringify(readdirSync(root).sort()) === JSON.stringify(expected), 'actual names');
check(JSON.stringify(readdirSync(root, 'utf8').sort()) === JSON.stringify(expected), 'UTF-8 encoding');
check(JSON.stringify(readdirSync(root, null).sort()) === JSON.stringify(expected), 'null defaults');
check(JSON.stringify((await promises.readdir(root)).sort()) === JSON.stringify(expected), 'promise names');
const predicates = ['isFile', 'isDirectory', 'isSymbolicLink', 'isBlockDevice', 'isCharacterDevice', 'isFIFO', 'isSocket'];
const kinds = { 'broken-link': 2, 'directory-link': 2, fifo: 5, 'file-link': 2, nested: 1, 'plain.txt': 0, socket: 6, 'space 🟢.txt': 0 };
for (const entries of [readdirSync(root, { withFileTypes: true }), await promises.readdir(root, { withFileTypes: true })]) {
  check(entries.length === expected.length, 'all directory entries');
  for (const entry of entries) {
    check(expected.includes(entry.name) && entry.parentPath === root, 'entry name/parent');
    const types = predicates.map(name => entry[name]());
    check(types.every((flag, index) => flag === (index === kinds[entry.name])), 'actual no-follow entry kind: ' + entry.name);
  }
}
check(JSON.stringify(readdirSync(root + '/nested')) === '["child.txt"]', 'nested directory');
const nullDevice = readdirSync('/dev', { withFileTypes: true }).find(entry => entry.name === 'null');
check(nullDevice && nullDevice.isCharacterDevice() && !nullDevice.isFile() && !nullDevice.isBlockDevice(), 'actual character device');
await promises.writeFile(root + '/added.txt', 'created after first listing');
check(readdirSync(root).includes('added.txt'), 'listings reflect real creation');
await promises.rm(root + '/added.txt');
check(!readdirSync(root).includes('added.txt'), 'listings reflect real removal');
for (const [path, code] of [[root + '/missing', 'ENOENT'], [root + '/plain.txt', 'ENOTDIR']]) {
  let sync;
  try { readdirSync(path); } catch (error) { sync = error; }
  check(sync && sync.code === code, 'actual sync OS error');
  let async;
  try { await promises.readdir(path); } catch (error) { async = error; }
  check(async && async.code === code, 'actual rejected OS error');
}
console.log('OK actual directory names, seven entry predicates, symlinks, mutations and OS errors');
