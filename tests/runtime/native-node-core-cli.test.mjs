import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

// These are native Home checks, not delegated Bun/Node compatibility results.
assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const env = {
  ...process.env,
  HOME_NATIVE_VM: '1',
  HOME_CORPUS_FULL_VM: '1',
  HOME_NATIVE_RUN: '0',
  NO_COLOR: '1',
}
function run(args, options = {}) {
  const child = spawnSync(process.execPath, args, {
    env,
    encoding: 'utf8',
    timeout: 10000,
    ...options,
  })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  return child
}

for (const [inputType, header] of [
  ['commonjs', 'const assert = require("node:assert/strict");'],
  ['module', 'import assert from "node:assert/strict";'],
]) {
  const source = header + ' assert.match(process.execPath, /home(?:-debug)?(?:\\.exe)?$/); console.log("native-eval-executed");'
  const success = run(['--input-type', inputType, '--eval', source])
  assert.equal(success.status, 0, success.stderr)
  assert.equal(success.stdout.trim(), 'native-eval-executed')

  const failure = run(['--input-type', inputType, '--eval', header + ' assert.ok(false, "native-assertion-sentinel");'])
  assert.equal(failure.status, 1)
  // Upstream only compares two extracted lines, allowing undefined ===
  // undefined when both children fail before evaluating the intended source.
  assert.match(failure.stderr, /AssertionError: native-assertion-sentinel/)
  assert.doesNotMatch(failure.stderr, /Module not found/)
}

const directory = mkdtempSync(join(tmpdir(), 'home-native-core-cli-'))
try {
  const fixture = join(directory, 'entry')
  writeFileSync(fixture, 'console.log(JSON.stringify(process.argv.slice(2)));')
  const implicit = run([fixture, 'test', '--no-warnings'])
  assert.equal(implicit.status, 0, implicit.stderr)
  assert.deepEqual(JSON.parse(implicit.stdout), ['test', '--no-warnings'])

  const missing = run([join(directory, 'missing-entry')])
  assert.equal(missing.status, 1)
  assert.match(missing.stderr, /not found/i)
  assert.match(missing.stderr, /missing-entry/)

  const testFile = join(directory, 'flags.test.js')
  writeFileSync(testFile, 'const { test } = require("node:test"); test("native test command", () => {});')
  const test = run(['--no-warnings', 'test', testFile])
  assert.equal(test.status, 0, test.stderr)
  assert.match(test.stdout + test.stderr, /1 pass/)
  assert.match(test.stdout + test.stderr, /Ran 1 test across 1 file/)

  // Native test CLI options (#481). Each fixture records the actual runtime
  // and body execution; a filtered test must not merely disappear from output.
  const prelude = `import { test, describe, expect, afterAll } from 'bun:test'; console.log('EXEC:' + process.execPath);\n`
  function makeFixture(name, source) {
    const path = join(directory, name)
    writeFileSync(path, prelude + source)
    return path
  }
  function invoke(args, options = {}) {
    return run(['test', ...args], { cwd: directory, ...options })
  }
  function passed(child, count) {
    assert.equal(child.status, 0, child.stderr)
    assert.ok(child.stdout.includes('EXEC:' + process.execPath), 'test ran outside the invoking runtime')
    if (count !== undefined) assert.match(child.stdout + child.stderr, new RegExp('\\b' + count + ' pass\\b'))
  }
  const selection = makeFixture('selection.test.js', `
    console.log('FIXTURE_LOADED');
    describe('outer', () => {
      test('keep blue', () => console.log('BODY:blue'));
      test('keep red', () => console.log('BODY:red'));
      test('poison', () => { console.log('BODY:poison'); throw new Error('excluded test executed'); });
    });
  `)
  const pattern = '^outer keep blue$'
  for (const flags of [
    ['-t', pattern], ['--test-name-pattern', pattern], ['--grep', pattern],
    ['--test-name-pattern=' + pattern], ['--grep=' + pattern], ['-t=' + pattern], ['-t' + pattern],
    ['-t', 'poison', '-t', pattern],
  ]) {
    for (const args of [[selection, ...flags], [...flags, selection]]) {
      const child = invoke(args)
      passed(child, 1)
      assert.match(child.stdout, /BODY:blue/)
      assert.doesNotMatch(child.stdout, /BODY:red|BODY:poison/)
      assert.match(child.stdout + child.stderr, /2 filtered out/)
    }
  }
  const separated = invoke(['-t', pattern, '--', selection])
  passed(separated, 1)
  assert.doesNotMatch(separated.stdout, /BODY:red|BODY:poison/)
  const unfiltered = invoke([selection])
  assert.equal(unfiltered.status, 1)
  assert.match(unfiltered.stdout, /BODY:poison/)
  const emptyPattern = invoke([selection, '-t', ''])
  assert.equal(emptyPattern.status, 1)
  assert.match(emptyPattern.stdout, /BODY:poison/)
  const noMatch = invoke([selection, '--grep', '^missing-name$'])
  assert.equal(noMatch.status, 1, noMatch.stderr)
  assert.doesNotMatch(noMatch.stdout, /BODY:/)
  assert.match(noMatch.stdout + noMatch.stderr, /matched 0 tests/)

  for (const flags of [
    ['-t'], ['--grep'], ['--test-name-pattern'], ['-t', '['],
    ['--timeout', 'nope'], ['--bail=0'], ['--retry=1', '--rerun-each=2'],
    ['--seed=nope'], ['--shard=0/2'], ['--max-concurrency=-1'],
    ['--port=65536'], ['--use-system-ca', '--use-bundled-ca'],
  ]) {
    const child = invoke([selection, ...flags])
    assert.equal(child.status, 1, flags.join(' ') + '\n' + child.stderr)
    assert.doesNotMatch(child.stdout, /FIXTURE_LOADED|BODY:/, 'invalid arguments executed user code: ' + flags.join(' '))
    assert.match(child.stderr, /error|argument|option/i)
  }

  // Bun tolerates unknown runtime flags; they must not disable recognized filters.
  passed(invoke([selection, '--definitely-unknown-home-test-option', '-t', pattern]), 1)

  const basic = makeFixture('basic.test.js', `test('basic', () => console.log('BODY:basic'));`)
  const serial = invoke([basic])
  passed(serial, 1)
  assert.match(serial.stderr, /basic\.test\.js:\n\(pass\) basic/)
  for (const value of ['false', '0']) {
    const noGroups = invoke([basic], { env: { ...env, GITHUB_ACTIONS: value } })
    passed(noGroups, 1)
    assert.doesNotMatch(noGroups.stderr, /::group::|::endgroup::/)
  }
  const repeated = invoke([basic, '--rerun-each=3'])
  passed(repeated, 3)
  assert.equal(repeated.stdout.match(/BODY:basic/g)?.length, 3)
  const retry = makeFixture('retry.test.js', `let attempt = 0; test('retry', () => { console.log('ATTEMPT:' + ++attempt); expect(attempt).toBe(2); });`)
  const retried = invoke([retry, '--retry', '1'])
  passed(retried, 1)
  assert.match(retried.stdout, /ATTEMPT:1[\s\S]*ATTEMPT:2/)
  const fail = makeFixture('bail.test.js', `
    test('first', () => { console.log('BODY:first'); expect(false).toBe(true); });
    test('second', () => { console.log('BODY:second'); expect(false).toBe(true); });
  `)
  for (const flags of [['--bail'], ['--bail=1']]) {
    const bailed = invoke([fail, ...flags])
    assert.equal(bailed.status, 1)
    assert.match(bailed.stdout, /BODY:first/)
    assert.doesNotMatch(bailed.stdout, /BODY:second/)
  }
  const only = invoke([selection, '--only'])
  assert.equal(only.status, 0, only.stderr)
  assert.doesNotMatch(only.stdout, /BODY:/)
  const slow = makeFixture('timeout.test.js', `test('slow', async () => { await new Promise(resolve => setTimeout(resolve, 80)); console.log('BODY:slow'); });`)
  const timedOut = invoke([slow, '--timeout=10'])
  assert.equal(timedOut.status, 1)
  assert.match(timedOut.stderr, /timed out after 10ms/)
  passed(invoke([slow, '--timeout', '1000']), 1)

  const emptyDirectory = join(directory, 'empty')
  mkdirSync(emptyDirectory)
  assert.equal(invoke([], { cwd: emptyDirectory }).status, 1)
  assert.equal(invoke(['--pass-with-no-tests'], { cwd: emptyDirectory }).status, 0)

  const configured = join(directory, 'configured')
  mkdirSync(configured)
  writeFileSync(join(configured, 'setup.js'), 'globalThis.CLI_PRELOAD = 42;')
  writeFileSync(join(configured, 'bunfig.toml'), '[test]\npreload = ["./setup.js"]\nrerunEach = 2\n')
  writeFileSync(join(configured, 'config.test.js'), prelude + 'test("config", () => expect(globalThis.CLI_PRELOAD).toBe(42));')
  passed(invoke(['--cwd', configured]), 2)
  for (const config of [
    '[test]\nseed = 2444615283\n',
    '[test]\nrandomize = false\nseed = 2444615283\n',
    '[test]\nrandomize = "invalid"\n',
    '[test]\nseed = [\n',
  ]) {
    writeFileSync(join(configured, 'bunfig.toml'), config)
    const invalidConfig = invoke(['--cwd', configured])
    assert.equal(invalidConfig.status, 1, invalidConfig.stderr)
    assert.doesNotMatch(invalidConfig.stdout, /EXEC:/, 'invalid config executed user code')
    assert.match(invalidConfig.stderr, /error|Invalid Bunfig/i)
    assert.doesNotMatch(invalidConfig.stderr, /panic|crash\(\) called/)
  }
  const customConfig = join(directory, 'custom.toml')
  writeFileSync(customConfig, '[test]\nrerunEach = 2\n')
  passed(invoke([basic, '--config=' + customConfig]), 2)
  const missingConfig = invoke([basic, '--config=' + join(directory, 'missing.toml')])
  assert.equal(missingConfig.status, 1)
  assert.doesNotMatch(missingConfig.stdout, /EXEC:/)
  assert.match(missingConfig.stderr, /while reading config/)
  const preload = join(directory, 'preload.js')
  writeFileSync(preload, 'globalThis.CLI_PRELOAD = 42;')
  const preloadTest = makeFixture('preload.test.js', 'test("preload", () => expect(globalThis.CLI_PRELOAD).toBe(42));')
  for (const name of ['--preload', '--require', '--import', '-r']) passed(invoke([preloadTest, name, preload]), 1)
  const define = makeFixture('define.test.js', 'test("define", () => expect(CLI_DEFINED).toBe(42));')
  passed(invoke([define, '--define', 'CLI_DEFINED:42']), 1)
  const title = makeFixture('title.test.js', 'test("title", () => expect(process.title).toBe("home-test-cli-title"));')
  passed(invoke([title, '--title', 'home-test-cli-title']), 1)

  const junit = join(directory, 'results.xml')
  passed(invoke([basic, '--reporter=junit', '--reporter-outfile', junit]), 1)
  assert.equal(existsSync(junit), true)
  assert.match(readFileSync(junit, 'utf8'), /<testcase[^>]*name="basic"/)
  passed(invoke([basic, '--dots']))

  const order = makeFixture('order.test.js', `for (const name of ['alpha','bravo','charlie','delta','echo']) test(name, () => console.log('ORDER:' + name));`)
  const firstOrder = invoke([order, '--randomize', '--seed=2444615283'])
  const secondOrder = invoke([order, '--seed', '2444615283'])
  passed(firstOrder, 5)
  passed(secondOrder, 5)
  const orderFrom = child => [...child.stdout.matchAll(/ORDER:(\w+)/g)].map(match => match[1])
  assert.deepEqual(orderFrom(firstOrder), orderFrom(secondOrder))
  assert.deepEqual([...orderFrom(firstOrder)].sort(), ['alpha', 'bravo', 'charlie', 'delta', 'echo'])
  assert.notDeepEqual(orderFrom(firstOrder), ['alpha', 'bravo', 'charlie', 'delta', 'echo'])

  const shards = join(directory, 'shards')
  mkdirSync(shards)
  for (const name of ['left', 'right']) writeFileSync(join(shards, name + '.test.js'), prelude + `test('${name}', () => console.log('SHARD:${name}'));`)
  const shard1 = invoke([shards, '--shard=1/2'])
  const shard2 = invoke([shards, '--shard=2/2'])
  passed(shard1, 1)
  passed(shard2, 1)
  const shardNames = [shard1, shard2].flatMap(child => [...child.stdout.matchAll(/SHARD:(\w+)/g)].map(match => match[1])).sort()
  assert.deepEqual(shardNames, ['left', 'right'])

  const concurrency = makeFixture('concurrency.test.js', `
    let active = 0, peak = 0, completed = 0;
    for (let i = 0; i < 5; i++) test('task ' + i, async () => {
      peak = Math.max(peak, ++active);
      await new Promise(resolve => setTimeout(resolve, 15));
      active--; completed++;
    });
    afterAll(() => { expect(peak).toBe(2); expect(completed).toBe(5); console.log('PEAK:' + peak); });
  `)
  const concurrent = invoke([concurrency, '--concurrent', '--max-concurrency=2'])
  passed(concurrent, 5)
  assert.match(concurrent.stdout, /PEAK:2/)
  console.log('native test CLI option regressions passed')
} finally {
  rmSync(directory, { recursive: true })
}
console.log('native node core CLI regressions passed')
