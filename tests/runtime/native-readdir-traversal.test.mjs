import assert from 'node:assert/strict'
import fs from 'node:fs'
import { readdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, relative, resolve, sep } from 'node:path'
const root = fs.mkdtempSync(join(tmpdir(), 'home-readdir-traversal-'))
const normalize = value => value.split(sep).join('/')
const paths = values => values.map(item => normalize(relative(root, join(item.parentPath ?? item.path, item.name)))).sort()
try {
  fs.mkdirSync(join(root, 'a', 'nested'), { recursive: true })
  fs.mkdirSync(join(root, 'é'), { recursive: true })
  fs.writeFileSync(join(root, 'a', 'nested', 'file.txt'), 'one')
  fs.writeFileSync(join(root, 'é', '日本語.txt'), 'two')
  if (process.platform !== 'win32') fs.writeFileSync(join(root, 'literal\\name'), 'three')
  const expected = ['a', 'a/nested', 'a/nested/file.txt', 'é', 'é/日本語.txt']
  if (process.platform !== 'win32') expected.push('literal\\name')
  expected.sort()
  for (const input of [root, root + sep, relative(process.cwd(), root), root + sep + '..' + sep + root.split(sep).at(-1)]) {
    assert.deepEqual(fs.readdirSync(input, { recursive: true }).map(normalize).sort(), expected)
    assert.deepEqual((await readdir(input, { recursive: true })).map(normalize).sort(), expected)
    assert.deepEqual(paths(fs.readdirSync(input, { recursive: true, withFileTypes: true })), expected)
    assert.deepEqual(paths(await readdir(input, { recursive: true, withFileTypes: true })), expected)
  }
  const first = fs.readdirSync(root, { recursive: true, withFileTypes: true })
  fs.renameSync(join(root, 'a', 'nested', 'file.txt'), join(root, 'a', 'nested', 'renamed.txt'))
  const after = await readdir(root, { recursive: true, withFileTypes: true })
  assert.ok(paths(first).includes('a/nested/file.txt'))
  assert.ok(paths(after).includes('a/nested/renamed.txt'))
  assert.ok(!paths(after).includes('a/nested/file.txt'))
  for (const row of after) assert.equal(resolve(row.parentPath ?? row.path), resolve(join(root, relative(root, join(row.parentPath ?? row.path, row.name)), '..')))
  fs.rmSync(join(root, 'a'), { recursive: true })
  assert.deepEqual(fs.readdirSync(root, { recursive: true }).map(normalize).sort(), expected.filter(name => !name.startsWith('a')))
  console.log('native recursive traversal, parent paths, Unicode, literal separators, mutation freshness and result ownership passed')
} finally {
  fs.rmSync(root, { recursive: true, force: true })
}
