import assert from 'node:assert/strict'
import fs from 'node:fs'
import { readdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, sep } from 'node:path'

const hostGaps = []
const root = fs.mkdtempSync(join(tmpdir(), 'home-readdir-encoding-'))
const callbackRead = (path, options) => new Promise((resolve, reject) => fs.readdir(path, options, (error, value) => error ? reject(error) : resolve(value)))
const readers = [
  (path, options) => fs.readdirSync(path, options),
  callbackRead,
  readdir,
]
const names = [Buffer.from('é'), Buffer.from('日本語.txt'), Buffer.from('second.txt')]
const encode = (bytes, encoding) => encoding === 'buffer' ? bytes : bytes.toString(encoding)
const key = value => Buffer.isBuffer(value) ? value.toString('hex') : value

try {
  fs.mkdirSync(join(root, 'é'))
  fs.writeFileSync(join(root, 'é', '日本語.txt'), 'one')
  fs.writeFileSync(join(root, 'é', 'second.txt'), 'two')
  for (const read of readers) {
    for (const input of [root, root + sep, Buffer.from(root), Buffer.from(root + sep)]) {
      for (const encoding of ['utf8', 'buffer', 'latin1', 'hex', 'base64', 'base64url', 'ascii', 'utf16le', 'ucs2']) {
        for (const recursive of [false, true]) {
          const rows = await read(input, { withFileTypes: true, recursive, encoding })
          const expected = (recursive ? names : names.slice(0, 1)).map(name => encode(name, encoding))
          assert.deepEqual(rows.map(row => key(row.name)).sort(), expected.map(key).sort())
          for (const row of rows) {
            const name = key(row.name)
            const isDirectory = name === key(encode(names[0], encoding))
            assert.equal(row.isDirectory(), isDirectory)
            assert.equal(row.isFile(), !isDirectory)
            assert.equal(Buffer.isBuffer(row.name), encoding === 'buffer')
            if (isDirectory) assert.equal(row.parentPath, input)
            else {
              const encodedDirectory = encode(names[0], encoding)
              const parent = Buffer.isBuffer(input) || encoding === 'buffer'
                ? Buffer.concat([Buffer.isBuffer(input) ? input : Buffer.from(input), Buffer.isBuffer(input) ? (input.at(-1) === sep.charCodeAt(0) ? Buffer.alloc(0) : Buffer.from(sep)) : (input.endsWith(sep) ? Buffer.alloc(0) : Buffer.from(sep)), Buffer.isBuffer(encodedDirectory) ? encodedDirectory : Buffer.from(encodedDirectory)])
                : join(input, encodedDirectory)
              assert.equal(Buffer.isBuffer(row.parentPath), encoding === 'buffer' || Buffer.isBuffer(input))
              assert.deepEqual(row.parentPath, parent)
            }
          }
          const children = rows.filter(row => row.isFile())
          if (children.length === 2) assert.equal(children[0].parentPath, children[1].parentPath)
        }
      }
    }
    // Plain recursive arrays must apply the same requested encoding.
    for (const encoding of ['utf8', 'latin1', 'hex', 'base64', 'base64url', 'ascii', 'utf16le', 'ucs2', 'buffer']) {
      const rows = await read(root, { recursive: true, encoding })
      const expected = ['é', join('é', '日本語.txt'), join('é', 'second.txt')].map(name => encode(Buffer.from(name), encoding))
      assert.deepEqual(rows.map(key).sort(), expected.map(key).sort())
    }
  }

  if (process.platform !== 'win32') {
    const bytes = Buffer.from([0xff, 0x61])
    const path = Buffer.concat([Buffer.from(root + sep), bytes])
    let rawNamesSupported = true
    try { fs.mkdirSync(path) } catch (error) {
      if (error.code !== 'EILSEQ') throw error
      rawNamesSupported = false
      hostGaps.push('invalid UTF-8 filenames rejected by host filesystem: EILSEQ')
    }
    if (rawNamesSupported) {
      fs.writeFileSync(Buffer.concat([path, Buffer.from(sep), Buffer.from([0xfe, 0x62])]), 'raw')
      for (const read of readers) {
        const rows = await read(root, { recursive: true, withFileTypes: true, encoding: 'buffer' })
        const directory = rows.find(row => row.name.equals(bytes))
        const child = rows.find(row => row.name.equals(Buffer.from([0xfe, 0x62])))
        assert(directory?.isDirectory())
        assert(child?.isFile())
        assert.deepEqual(child.parentPath, path)
      }
    }
  }

  fs.mkdirSync(join(root, 'é', 'nested'))
  fs.writeFileSync(join(root, 'é', 'nested', 'deep'), 'deep')
  for (const read of readers) {
    for (const encoding of ['utf8', 'buffer', 'latin1', 'hex', 'base64', 'base64url', 'ascii', 'utf16le', 'ucs2']) {
      const rows = await read(root, { recursive: true, withFileTypes: true, encoding })
      const deep = rows.find(row => key(row.name) === key(encode(Buffer.from('deep'), encoding)))
      assert(deep)
      const relativeParent = encode(Buffer.from(join('é', 'nested')), encoding)
      const parent = Buffer.isBuffer(relativeParent)
        ? Buffer.concat([Buffer.from(root + sep), relativeParent])
        : join(root, relativeParent)
      assert.deepEqual(deep.parentPath, parent)
    }
  }

  const surrogateDirectory = 'a\u060Fb'
  fs.mkdirSync(join(root, surrogateDirectory))
  fs.writeFileSync(join(root, surrogateDirectory, 'child'), 'surrogate')
  for (const read of readers) {
    for (const input of [root, Buffer.from(root)]) {
      const rows = await read(input, { recursive: true, withFileTypes: true, encoding: 'utf16le' })
      const child = rows.find(row => row.name === Buffer.from('child').toString('utf16le'))
      assert(child)
      const decodedDirectory = Buffer.from(surrogateDirectory).toString('utf16le')
      const expectedParent = Buffer.isBuffer(input)
        ? Buffer.concat([input, Buffer.from(sep), Buffer.from(decodedDirectory)])
        : root + sep + decodedDirectory
      assert.deepEqual(child.parentPath, expectedParent)
    }
  }

  const concurrentRoot = fs.mkdtempSync(join(tmpdir(), 'home-readdir-concurrent-'))
  try {
    for (let index = 0; index < 128; index++) {
      fs.mkdirSync(join(concurrentRoot, String(index)))
      fs.writeFileSync(join(concurrentRoot, String(index), 'file'), 'shared')
    }
    const results = await Promise.all(Array.from({ length: 64 }, () => readdir(concurrentRoot, { recursive: true, withFileTypes: true })))
    for (const rows of results) {
      assert.equal(rows.length, 256)
      assert.equal(rows.filter(row => row.isDirectory()).length, 128)
      assert.equal(rows.filter(row => row.isFile()).length, 128)
    }
  } finally { fs.rmSync(concurrentRoot, { recursive: true, force: true }) }

  const retained = await readdir(root, { recursive: true, withFileTypes: true, encoding: 'buffer' })
  const before = retained.map(row => Buffer.from(row.name))
  fs.renameSync(join(root, 'é', 'second.txt'), join(root, 'é', 'renamed.txt'))
  const after = await readdir(root, { recursive: true, withFileTypes: true, encoding: 'buffer' })
  assert(after.some(row => row.name.equals(Buffer.from('renamed.txt'))))
  assert(!after.some(row => row.name.equals(Buffer.from('second.txt'))))
  globalThis.Bun?.gc(true)
  globalThis.gc?.()
  for (let index = 0; index < retained.length; index++) assert.deepEqual(retained[index].name, before[index])
  console.log(JSON.stringify({ passed: true, hostGaps, coverage: 'Dirent raw names, parent values/identity, encodings, kinds and retained-buffer ownership' }))
} finally {
  fs.rmSync(root, { recursive: true, force: true })
}
