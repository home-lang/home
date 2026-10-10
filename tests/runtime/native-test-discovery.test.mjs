import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const fixture = mkdtempSync(join(tmpdir(), 'home-test-discovery-'))
const env = { ...process.env, HOME_NATIVE_VM: '1', HOME_CORPUS_FULL_VM: '1', HOME_NATIVE_RUN: '0', NO_COLOR: '1' }
const source = marker => `
import { test, expect } from 'bun:test';
test(${JSON.stringify(marker)}, () => {
  for (const stdin of ['ignore', 'inherit', 'pipe']) {
    const child = Bun.spawnSync(['/bin/sh', '-c', 'echo OUT; echo ERR >&2'], {
      stdin, stdout: 'pipe', stderr: 'pipe', timeout: 10000
    });
    expect(child.exitCode).toBe(0);
    expect(child.stdout.toString()).toBe('OUT\\n');
    expect(child.stderr.toString()).toBe('ERR\\n');
  }
  console.log(${JSON.stringify(marker)});
});
`
function run(args, markers) {
  const child = spawnSync(process.execPath, ['test', ...args], {
    cwd: fixture, env, encoding: 'utf8', timeout: 60000,
  })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  assert.equal(child.status, 0, child.stderr)
  for (const marker of markers) assert.equal(child.stdout.split(marker).length - 1, 1, child.stdout)
  assert.match(child.stderr, new RegExp(`${markers.length} pass`))
  assert.match(child.stderr, /0 fail/)
}
try {
  // Exceeds Darwin's posix_spawn OPEN_MAX without changing the process limit.
  // Discovery must close its directory handles before running user tests.
  const tree = join(fixture, 'tree')
  mkdirSync(tree)
  for (let index = 0; index < 11000; index++) mkdirSync(join(tree, String(index)))
  const nested = join(tree, '10999', 'nested')
  mkdirSync(nested)
  writeFileSync(join(nested, 'capture.test.ts'), source('large-tree-native-capture'))
  run(['capture'], ['large-tree-native-capture'])

  const other = join(fixture, 'other')
  mkdirSync(other)
  writeFileSync(join(other, 'second.test.ts'), source('second-root-native-capture'))
  // Revisit cached roots and their children while retaining each test once.
  run(['./tree', './tree', './tree/10999', './other'], ['large-tree-native-capture', 'second-root-native-capture'])

  if (process.platform !== 'win32') {
    symlinkSync('tree/10999/nested', join(fixture, 'linked'))
    run(['./linked'], ['large-tree-native-capture'])
  }
  // Corpus dispatch must preserve the native runner's name filter too.
  const corpus = join(fixture, 'packages/runtime/test/test/js/node/filter-fixture')
  mkdirSync(corpus, { recursive: true })
  const filteredSource = `import { test, describe } from 'bun:test';
    describe('outer', () => {
      test('keep blue', () => console.log('CORPUS:blue'));
      test('keep red', () => { console.log('CORPUS:red'); throw new Error('excluded body executed'); });
    });`
  const first = join(corpus, 'first.test.js')
  const second = join(corpus, 'second.test.js')
  writeFileSync(first, filteredSource)
  writeFileSync(second, filteredSource)
  writeFileSync(join(fixture, 'packages/runtime/test/test/BUN_TRACKED_FILES.txt'),
    'js/node/filter-fixture/first.test.js\njs/node/filter-fixture/second.test.js\n')
  const corpusEnv = { ...env }
  for (const key of ['HOME_NATIVE_VM', 'HOME_CORPUS_FULL_VM', 'HOME_NATIVE_RUN', 'HOME_BUN_CORPUS_REPORT_DIR']) delete corpusEnv[key]
  function runCorpus(args, count) {
    const child = spawnSync(process.execPath, ['test', ...args], {
      cwd: fixture, env: corpusEnv, encoding: 'utf8', timeout: 60000,
    })
    assert.equal(child.error, undefined)
    assert.equal(child.signal, null)
    assert.equal(child.status, 0, child.stderr)
    assert.equal(child.stdout.split('CORPUS:blue').length - 1, count, child.stdout)
    assert.doesNotMatch(child.stdout, /CORPUS:red/)
    assert.match(child.stdout + child.stderr, new RegExp(`(?:${count} pass|tests passed: ${count}\\b)`))
    return child
  }
  const pattern = '^outer keep blue$'
  for (const flags of [
    ['-t', pattern], ['--test-name-pattern', pattern], ['--grep', pattern],
    [`--test-name-pattern=${pattern}`], [`--grep=${pattern}`], [`-t=${pattern}`], [`-t${pattern}`],
  ]) {
    for (const args of [[first, ...flags], [...flags, first]]) runCorpus(args, 1)
  }
  runCorpus(['-t', pattern, '--', first], 1)
  runCorpus([first, second, '--grep', pattern], 2)
  runCorpus([corpus, '--test-name-pattern', pattern], 2)
  for (const flags of [['-t'], ['-t', '['], ['--grep', '^missing$']]) {
    const child = spawnSync(process.execPath, ['test', first, ...flags], {
      cwd: fixture, env: corpusEnv, encoding: 'utf8', timeout: 60000,
    })
    assert.equal(child.status, 1, child.stderr)
    assert.doesNotMatch(child.stdout, /CORPUS:/)
  }
  console.log('native large-tree discovery, cached roots, symlink discovery and corpus name filters passed')
} finally {
  rmSync(fixture, { recursive: true, force: true })
}
