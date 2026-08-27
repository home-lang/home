import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-empty-modules-'))
const env = { ...process.env, HOME_NATIVE_VM: '1', HOME_NATIVE_RUN: '0', NO_COLOR: '1' }
function run(args) {
  const child = spawnSync(process.execPath, args, { env, encoding: 'utf8', timeout: 10000 })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null, child.stderr.slice(0, 1000))
  assert.equal(child.status, 0, child.stderr.slice(0, 1000))
  return child
}
try {
  const sources = [
    ['', 'empty.cjs'],
    ['// only a comment\n', 'comment.cjs'],
    ['/* only a block comment */\n', 'block.cjs'],
    ['"use strict";\n', 'directive.cjs'],
    ['"use strict";\n// disabled upstream test body\n', 'strict-comment.cjs'],
    [';\n;\n', 'semicolons.cjs'],
    ['#!/usr/bin/env home\n// no executable statements\n', 'hashbang.cjs'],
    ['// empty JavaScript module\n', 'comment.js'],
  ]
  for (const [source, name] of sources) {
    const file = join(directory, name)
    writeFileSync(file, source)
    assert.equal(run(['run', file]).stdout, '')
    const expression = 'const assert = require("node:assert/strict"); const loaded = require('
      + JSON.stringify(file) + '); '
      + (name.endsWith('.cjs') ? 'assert.deepEqual(loaded, {});' : 'assert.deepEqual(Object.keys(loaded), []);')
      + ' console.log("empty-module-loaded");'
    assert.equal(run(['--eval', expression]).stdout.trim(), 'empty-module-loaded')
  }

  // Existing non-empty parts must retain their symbol metadata.
  const populated = join(directory, 'populated.cjs')
  writeFileSync(populated, 'const value = 21; module.exports = { answer: value * 2 };')
  const expression = 'const assert = require("node:assert/strict"); assert.equal(require('
    + JSON.stringify(populated) + ').answer, 42); console.log("populated-module-loaded");'
  assert.equal(run(['--eval', expression]).stdout.trim(), 'populated-module-loaded')
} finally {
  rmSync(directory, { recursive: true })
}
console.log('native empty module regressions passed')
