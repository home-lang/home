import { mkdir, readFile, writeFile } from 'node:fs/promises';

function check(value, message) { if (!value) throw new Error(message); }
const root = process.argv[2];
for (const [name, mode] of [['private', 0o600], ['octal', '640'], ['logger', 0o644], ['executable', 0o777], ['default', undefined], ['null', null]]) {
  check(await writeFile(root + '/' + name, 'actual mode ' + name, { mode }) === undefined, 'write result');
  check(await readFile(root + '/' + name, 'utf8') === 'actual mode ' + name, 'actual file contents');
}
const backing = new Uint8Array([99, 0, 128, 255, 88]);
await writeFile(root + '/bytes', backing.subarray(1, 4), { mode: 0o640 });
await writeFile(root + '/existing.txt', 'overwritten', { mode: 0o777 });
await writeFile(root + '/link', 'through link', { mode: 0o777 });
check(await mkdir(root + '/leaf', { mode: '750' }) === undefined, 'leaf creation result');
check(await mkdir(root + '/parents/child', { recursive: true, mode: 0o755 }) === root + '/parents', 'recursive first created ancestor');
check(await mkdir(root + '/existing-dir', { recursive: true, mode: 0o777 }) === undefined, 'existing directory result');
check(await mkdir(root + '/existing-dir/child', { mode: 0o700 }) === undefined, 'child creation');
const invalid = [[-1, 'ERR_OUT_OF_RANGE'], [1.5, 'ERR_OUT_OF_RANGE'], [NaN, 'ERR_OUT_OF_RANGE'], [Infinity, 'ERR_OUT_OF_RANGE'], [4294967296, 'ERR_OUT_OF_RANGE'], [true, 'ERR_INVALID_ARG_TYPE'], [{}, 'ERR_INVALID_ARG_TYPE'], ['0o640', 'ERR_INVALID_ARG_VALUE'], ['', 'ERR_INVALID_ARG_VALUE'], ['888', 'ERR_INVALID_ARG_VALUE']];
for (let index = 0; index < invalid.length; index += 1) {
  const [mode, code] = invalid[index];
  for (const kind of ['file', 'directory']) {
    let error;
    const path = root + '/invalid-' + kind + '-' + index;
    try { if (kind === 'file') await writeFile(path, 'must not be created', { mode }); else await mkdir(path, { mode }); } catch (caught) { error = caught; }
    check(error && error.code === code, 'invalid mode must reject: ' + kind + ' ' + String(mode));
  }
}
console.log('OK actual creation and invalid-mode checks');
