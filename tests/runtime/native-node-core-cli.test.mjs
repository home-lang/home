import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { Readable } from 'node:stream'

// These are native Home checks, not delegated Bun/Node compatibility results.
assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

// Real ICU APIs, including buffer growth and stable per-process binding ownership.
const icu = process.binding('icu')
assert.equal(icu, process.binding('icu'))
assert.equal(icu.hasConverter('utf-8'), true)
assert.equal(icu.hasConverter('utf-16le'), true)
assert.equal(icu.hasConverter('x-home-invalid-encoding'), false)
assert.equal(icu.toASCII('bücher.example'), 'xn--bcher-kva.example')
assert.equal(icu.toUnicode('xn--bcher-kva.example'), 'bücher.example')
assert.equal(icu.toASCII('a'.repeat(8192)), 'a'.repeat(8192))
assert.throws(() => icu.toASCII('\uFFFD'), { code: 'ERR_INVALID_ARG_VALUE', name: 'TypeError', message: 'Cannot convert name to ASCII' })
assert.equal(typeof icu.toASCII('\uFFFD', true), 'string')
Bun.gc(true)
assert.equal(icu, process.binding('icu'))
console.log('native ICU conversion, growth and binding ownership passed')

const utf8Converter = icu.getConverter('utf-8', 0)
assert.equal(icu.getConverter('x-home-invalid-encoding', 0), undefined)
assert.equal(icu.decode(utf8Converter, Uint8Array.of(0xe2), 0, 'utf-8'), '')
assert.equal(icu.decode(utf8Converter, new DataView(Uint8Array.of(0x82, 0xac).buffer), 1, 'utf-8'), '€')
assert.equal(icu.decode(utf8Converter, Buffer.from('reused'), 1, 'utf-8'), 'reused')
assert.equal(icu.decode(utf8Converter, Uint8Array.of(0xef), 0, 'utf-8'), '')
assert.equal(icu.decode(utf8Converter, Uint8Array.of(0xbb), 0, 'utf-8'), '')
assert.equal(icu.decode(utf8Converter, Uint8Array.of(0xbf, 0x61), 1, 'utf-8'), 'a')
assert.equal(icu.decode(icu.getConverter('utf-8', 4), Uint8Array.of(0xef, 0xbb, 0xbf, 0x61), 1, 'utf-8'), '\uFEFFa')
const fatalConverter = icu.getConverter('utf-8', 2)
assert.equal(icu.decode(fatalConverter, Uint8Array.of(0xe2), 0, 'utf-8'), '')
assert.throws(() => icu.decode(fatalConverter, new Uint8Array(), 1, 'utf-8'), { code: 'ERR_ENCODING_INVALID_ENCODED_DATA' })
assert.equal(icu.decode(fatalConverter, Buffer.from('after-error'), 1, 'utf-8'), 'after-error')
assert.equal(icu.decode(icu.getConverter('windows-1252', 0), Uint8Array.of(0x80), 1, 'windows-1252'), '€')
const utf16Converter = icu.getConverter('utf-16le', 0)
assert.equal(icu.decode(utf16Converter, Uint8Array.of(0x3d, 0xd8), 0, 'utf-16le'), '')
assert.equal(icu.decode(utf16Converter, Uint8Array.of(0x00, 0xde), 1, 'utf-16le'), '😀')
const sharedDecode = new Uint8Array(new SharedArrayBuffer(2))
sharedDecode.set([0x68, 0x69])
assert.equal(icu.decode(icu.getConverter('utf-8', 0), sharedDecode.buffer, 1, 'utf-8'), 'hi')
assert.equal(icu.decode(utf8Converter, Buffer.from('x'.repeat(8192)), 1, 'utf-8'), 'x'.repeat(8192))
assert.throws(() => icu.decode({}, Buffer.from('x'), 1, 'utf-8'), { code: 'ERR_INVALID_ARG_TYPE' })
const detachedDecode = Uint8Array.of(0x61)
assert.throws(() => icu.decode(utf8Converter, detachedDecode, { valueOf() { detachedDecode.buffer.transfer(); return 1 } }, 'utf-8'), { code: 'ERR_INVALID_ARG_TYPE' })
assert.deepEqual(icu.transcode(Buffer.from('těst ☕'), 'utf8', 'latin1'), Buffer.from('t?st ?'))
assert.deepEqual(icu.transcode(Buffer.from('hä', 'latin1'), 'latin1', 'utf16le'), Buffer.from('hä', 'utf16le'))
assert.deepEqual(icu.transcode(Buffer.from('€'.repeat(4000), 'utf16le'), 'utf16le', 'utf8'), Buffer.from('€'.repeat(4000)))
assert.equal(icu.icuErrName(icu.transcode(Buffer.from('a'), 'bad', 'utf8')), 'U_ILLEGAL_ARGUMENT_ERROR')
assert.equal(icu.getStringWidth('abc'), 3)
assert.equal(icu.getStringWidth('你'), 2)
assert.equal(icu.getStringWidth('e\u0301'), 1)
assert.equal(icu.getStringWidth('·', true), 2)
assert.equal(icu.getStringWidth('👩‍👩‍👦', false, false), 2)
const weakConverters = []
for (let index = 0; index < 1024; index++) weakConverters.push(new WeakRef(icu.getConverter('utf-8', index % 2 ? 2 : 0)))
await Bun.sleep(1)
Bun.gc(true)
await Bun.sleep(1)
Bun.gc(true)
assert.ok(weakConverters.filter(ref => ref.deref() === undefined).length >= 1000)
console.log('native ICU streaming decode, transcode, width and converter lifetime passed')



// Bun pin 4982b91's howMuchToRead() retains the first byte chunk for
// unsized reads. Do not infer this contract from a different installed Bun.
const sourceBytes = new Uint8Array([99, 1, 2, 3, 99])
const view = sourceBytes.subarray(1, 4)
const secondChunk = Buffer.from([4, 5])
const readable = new Readable({ read() {} })
readable.push(view)
readable.push(secondChunk)
assert.equal(readable.readableLength, 5)
const normalized = readable.read()
assert.ok(Buffer.isBuffer(normalized))
assert.notEqual(normalized, view)
assert.equal(normalized.buffer, view.buffer)
assert.equal(normalized.byteOffset, view.byteOffset)
assert.deepEqual([...normalized], [1, 2, 3])
assert.equal(readable.read(), secondChunk)
assert.equal(readable.read(), null)
readable.push(view)
readable.push(secondChunk)
assert.deepEqual([...readable.read(4)], [1, 2, 3, 4])
assert.deepEqual([...readable.read()], [5])
readable.push(new DataView(sourceBytes.buffer, 2, 2))
assert.deepEqual([...readable.read()], [2, 3])
readable.push(null)
assert.equal(readable.read(), null)

const objectReadable = new Readable({ objectMode: true, read() {} })
objectReadable.push(view)
objectReadable.push(secondChunk)
assert.equal(objectReadable.read(0), null)
assert.equal(objectReadable.read(100), view)
assert.equal(objectReadable.read(), secondChunk)
objectReadable.push(null)
const iterated = []
for await (const chunk of Readable.from([view, secondChunk])) iterated.push(chunk)
assert.equal(iterated[0], view)
assert.equal(iterated[1], secondChunk)

const decoded = new Readable({ read() {} })
decoded.setEncoding('utf8')
decoded.push(Buffer.from([0xe2, 0x82]))
assert.equal(decoded.read(), null)
decoded.push(Buffer.from([0xac, 0x61, 0x62]))
decoded.push('cdefgh')
decoded.push(null)
assert.equal(decoded.read(6), '€abcde')
assert.equal(decoded.read(3), 'fgh')
assert.equal(decoded.read(), null)

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
  // Failed native spawn setup must report its errno, never watch pid 0 or
  // launch a child after silently discarding an invalid file action.
  const spawnFailures = join(directory, 'spawn-failures.cjs')
  writeFileSync(spawnFailures, `
    const assert = require('node:assert/strict');
    const { spawnSync, spawn } = require('node:child_process');
    const { getCounters } = require('bun:internal-for-testing');
    const { join } = require('node:path');
    const fs = require('node:fs');
    const missing = join(__dirname, 'missing-executable');
    const denied = join(__dirname, 'non-executable');
    fs.writeFileSync(denied, '#!/bin/sh\\nexit 91\\n', { mode: 0o644 });
    const countFDs = () => fs.readdirSync(process.platform === 'linux' ? '/proc/self/fd' : '/dev/fd').length;
    const before = process.platform === 'win32' ? 0 : countFDs();
    const countersBefore = getCounters();
    assert.deepEqual(Object.keys(countersBefore).sort(), ['spawnSync_blocking', 'spawn_memfd']);
    assert.ok(Number.isInteger(countersBefore.spawnSync_blocking));
    assert.ok(Number.isInteger(countersBefore.spawn_memfd));
    let ticked = false;
    process.nextTick(() => { ticked = true; });
    for (let round = 0; round < 32; round++) {
      for (const fn of [Bun.spawn, Bun.spawnSync]) {
        assert.throws(() => fn([missing]), e => e.code === 'ENOENT' && e.path === missing);
        if (process.platform !== 'win32') {
          assert.throws(() => fn([denied]), e => e.code === 'EACCES' && e.path === denied);
        }
      }
      const failed = spawnSync(missing, ['version']);
      assert.equal(failed.error.code, 'ENOENT');
      assert.equal(failed.error.path, missing);
      assert.deepEqual(failed.output, [null, null, null]);
      assert.equal(failed.signal, null);
      assert.notEqual(failed.status, 0);
      assert.throws(() => Bun.spawnSync([process.execPath, '-e', 'throw Error("unreachable")'], { cwd: missing }), e => e.code === 'ENOENT');
      if (process.platform !== 'win32') {
        const extraSockets = { stdio: ['ignore', 'ignore', 'ignore', 'socket-fd', 'socket-fd'] };
        assert.throws(() => Bun.spawn([missing], extraSockets), e => e.code === 'ENOENT');
        assert.throws(() => Bun.spawn([process.execPath, '-e', ''], { stdio: [...extraSockets.stdio, 10240] }), e => e.code === 'EBADF');
      }
    }
    if (process.platform !== 'win32') {
      assert.throws(() => fs.fstatSync(10240));
      const options = { stdio: ['ignore', 'pipe', 'pipe', 10240] };
      const failed = spawnSync(process.execPath, ['-e', 'throw Error("invalid fd executed")'], options);
      assert.equal(failed.error.code, 'EBADF');
      assert.deepEqual(failed.output, [null, null, null]);
      assert.throws(() => spawn(process.execPath, ['-e', 'throw Error("invalid fd executed")'], options), e => e.code === 'EBADF');
      assert.ok(countFDs() <= before + 2, 'failed spawn leaked descriptors');
    }
    const countersAfterFailures = getCounters();
    assert.equal(countersAfterFailures.spawnSync_blocking, countersBefore.spawnSync_blocking, 'failed spawns entered the blocking fast path');
    // Linux may create memfds before the OS rejects the executable.
    if (process.platform !== 'linux') assert.equal(countersAfterFailures.spawn_memfd, countersBefore.spawn_memfd);
    const fast = Bun.spawnSync([process.execPath, '-e', ''], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' });
    assert.equal(fast.exitCode, 0);
    const countersAfterFast = getCounters();
    assert.equal(countersAfterFast.spawnSync_blocking, countersBefore.spawnSync_blocking + (process.platform === 'win32' ? 0 : 1));
    assert.equal(countersAfterFast.spawn_memfd, countersAfterFailures.spawn_memfd);
    const recovered = Bun.spawnSync([process.execPath, '-e', 'console.log("recovered")'], { maxBuffer: 1024 });
    assert.equal(recovered.exitCode, 0);
    assert.equal(recovered.stdout.toString(), 'recovered\\n');
    assert.deepEqual(getCounters(), countersAfterFast, 'buffered spawn entered the blocking fast path');
    countersAfterFast.spawnSync_blocking = -100;
    assert.notEqual(getCounters().spawnSync_blocking, -100, 'snapshot mutation changed native counters');
    assert.notEqual(getCounters(), getCounters(), 'counter snapshots alias');
    assert.equal(ticked, false, 'spawnSync re-entered user microtasks');
    setImmediate(() => { assert.equal(ticked, true); console.log('spawn-failures-recovered'); });
  `)
  const spawnRecovery = run([spawnFailures], { env: { ...env, BUN_FEATURE_FLAG_INTERNAL_FOR_TESTING: '1' } })
  assert.equal(spawnRecovery.status, 0, spawnRecovery.stderr)
  assert.equal(spawnRecovery.stdout.trim(), 'spawn-failures-recovered')

  const stdioRejections = join(directory, 'stdio-rejections.mjs')
  writeFileSync(stdioRejections, `
    import assert from 'node:assert/strict';
    import { readdirSync } from 'node:fs';
    const fdCount = () => readdirSync(process.platform === 'linux' ? '/proc/self/fd' : '/dev/fd').length;
    const beforeFDs = process.platform === 'win32' ? 0 : fdCount();
    const memory = [];
    for (let batch = 0; batch < 6; batch++) {
      for (let i = 0; i < 16; i++) {
        (() => {
          const blob = new Blob([new Uint8Array(1024 * 1024).fill(65)], { type: 'application/x-home-rejection; version=1' });
          const value = i % 3 === 0 ? blob : i % 3 === 1 ? new Response(blob) : new Request('http://localhost/', { method: 'POST', body: blob });
          const bytes = new Uint8Array(1024 * 1024).fill(7);
          const stdin = i % 2 === 0 ? bytes : new Blob([bytes]);
          assert.throws(() => Bun.spawn([process.execPath, '-e', ''], {
            stdio: [stdin, 'ignore', 'ignore', value],
          }), e => e.code === 'ERR_INVALID_ARG_TYPE' && e.message === 'Blob cannot be used for stdio[3] yet');
          assert.equal(blob.size, 1024 * 1024, 'rejection detached the caller Blob');
        })();
        Bun.gc(true);
      }
      await Bun.sleep(0);
      Bun.gc(true);
      memory.push(process.memoryUsage().rss);
    }
    // Warm the allocator first; retained payloads otherwise grow by far more
    // than this bound after later option parsing rejects the spawn.
    assert.ok(memory.at(-1) - memory[0] < 32 * 1024 * 1024, 'rejected Blob stores retained: ' + JSON.stringify(memory));
    const retained = new Blob(['still readable'], { type: 'text/x-home; charset=utf-8' });
    assert.throws(() => Bun.spawn([process.execPath, '-e', ''], { stdio: ['ignore', 'ignore', 'ignore', retained] }));
    assert.equal(await retained.text(), 'still readable');
    for (let round = 0; round < 16; round++) {
      for (const fn of [Bun.spawn, Bun.spawnSync]) {
        for (const kind of ['stream', 'response', 'request']) {
          let cancelled = false;
          const stream = new ReadableStream({ cancel() { cancelled = true; } });
          const value = kind === 'stream' ? stream : kind === 'response' ? new Response(stream) : new Request('http://localhost/', { method: 'POST', body: stream });
          const expected = fn === Bun.spawnSync && kind !== 'stream' ? 'ReadableStream cannot be used in sync mode' : 'ReadableStream cannot be used for stdio[5] yet';
          assert.throws(() => fn([process.execPath, '-e', 'throw Error("rejected input executed")'], {
            stdio: ['ignore', 'ignore', 'ignore', 'ignore', 'ignore', value],
          }), e => e.code === 'ERR_INVALID_ARG_TYPE' && e.message === expected);
          assert.equal(cancelled, false);
          assert.equal(stream.locked, false);
          await stream.cancel();
        }
      }
    }
    Bun.gc(true);
    if (process.platform !== 'win32') assert.ok(fdCount() <= beforeFDs + 2, 'rejected stdio leaked descriptors');
    const child = Bun.spawnSync([process.execPath, '-e', 'console.log("empty-stdio-ok")'], {
      stdio: ['ignore', 'pipe', 'pipe', new Blob([]), new Response(''), new Blob([])],
    });
    assert.equal(child.exitCode, 0);
    assert.equal(child.stdout.toString(), 'empty-stdio-ok\\n');
    assert.equal(child.stderr.toString(), '');
    console.log('stdio-rejections-recovered');
  `)
  const rejectedStdio = run([stdioRejections])
  assert.equal(rejectedStdio.status, 0, rejectedStdio.stderr)
  assert.equal(rejectedStdio.stdout.trim(), 'stdio-rejections-recovered')

  const ownedInput = join(directory, 'stdio-owned-input.mjs')
  writeFileSync(ownedInput, `
    import assert from 'node:assert/strict';
    const length = 2 * 1024 * 1024;
    for (const kind of ['arraybuffer', 'uint8', 'dataview', 'buffer']) {
      for (const action of ['mutate', 'transfer']) {
        const offset = kind === 'arraybuffer' ? 0 : 7;
        const bytes = new Uint8Array(length + offset * 2).fill(7);
        bytes.subarray(offset, offset + length).fill(65);
        const input = kind === 'arraybuffer' ? bytes.buffer : kind === 'uint8' ? bytes.subarray(offset, offset + length) : kind === 'dataview' ? new DataView(bytes.buffer, offset, length) : Buffer.from(bytes.buffer, offset, length);
        const child = Bun.spawn([process.execPath, '-e', 'await Bun.sleep(10); const b = new Uint8Array(await Bun.stdin.arrayBuffer()); let changed = 0; for (const x of b) if (x !== 65) changed++; console.log(JSON.stringify({length: b.length, changed}));'], {
          stdin: input, stdout: 'pipe', stderr: 'pipe',
        });
        if (action === 'mutate') {
          bytes.fill(66);
        } else {
          let transferred = structuredClone(bytes.buffer, { transfer: [bytes.buffer] });
          assert.equal(bytes.buffer.byteLength, 0);
          transferred = null;
          Bun.gc(true);
        }
        const [stdout, stderr, code] = await Promise.all([child.stdout.text(), child.stderr.text(), child.exited]);
        assert.equal(code, 0, stderr);
        assert.equal(stderr, '');
        assert.deepEqual(JSON.parse(stdout), { length, changed: 0 }, kind + ' ' + action);
      }
    }
    console.log('stdio-owned-input-ok');
  `)
  const inputSnapshot = run([ownedInput])
  assert.equal(inputSnapshot.status, 0, inputSnapshot.stderr)
  assert.equal(inputSnapshot.stdout.trim(), 'stdio-owned-input-ok')

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

  // Native parallel workers must be distinct Home subprocesses rather than a
  // serial fallback with fabricated worker identifiers.
  const parallelIds = join(directory, 'parallel-worker-ids.txt')
  const parallelBody = `
    import assert from 'node:assert/strict';
    import { appendFileSync } from 'node:fs';
    test('parallel worker', async () => {
      assert.match(process.execPath, /home(?:-debug)?(?:\\.exe)?$/);
      appendFileSync(${JSON.stringify(parallelIds)}, process.env.JEST_WORKER_ID + ':' + process.pid + '\\n');
      await Bun.sleep(150);
    });
  `
  const parallelA = makeFixture('parallel-a.test.js', parallelBody)
  const parallelB = makeFixture('parallel-b.test.js', parallelBody)
  const parallel = invoke(['--parallel=2', parallelA, parallelB], {
    env: { ...env, BUN_TEST_PARALLEL_SCALE_MS: '0' },
  })
  assert.equal(parallel.status, 0, parallel.stderr)
  assert.ok((parallel.stdout + parallel.stderr).includes('EXEC:' + process.execPath), 'parallel test ran outside the invoking runtime')
  assert.match(parallel.stdout + parallel.stderr, /\b2 pass\b/)
  const workerIds = readFileSync(parallelIds, 'utf8').trim().split('\n')
  assert.equal(workerIds.length, 2)
  assert.equal(new Set(workerIds.map(line => line.split(':')[0])).size, 2)
  assert.equal(new Set(workerIds.map(line => line.split(':')[1])).size, 2)

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
  // The upstream isolation suite covers ordinary leaked handles. Exercise
  // the second timer heap, long AbortSignal pins, explicit handle removal,
  // and watchFile initial work still in flight at a file boundary as well.
  for (const mode of ['native-handles', 'fake-timers']) {
    const isolated = join(directory, 'isolated-' + mode)
    mkdirSync(isolated)
    for (let i = 0; i < 8; i++) {
      const leak = mode === 'native-handles'
        ? `
          const options = { port: 0, development: ${i % 2 === 0}, fetch: () => new Response('x'), error: () => new Response('error') };
          const server = Bun.serve(options);
          server.reload(options); server.reload(options);
          server.stop(true);
          const watcher = fs.watch(import.meta.dir, () => {});
          watcher.close(); watcher.close();
          fs.watchFile(import.meta.path, { interval: 5 }, () => { throw new Error('stale stat callback'); });
          const signal = AbortSignal.timeout(3_600_000);
          signal.addEventListener('abort', () => { throw new Error('stale abort callback'); });
        `
        : `
          jest.useRealTimers();
          jest.useFakeTimers();
          expect(jest.isFakeTimers()).toBe(true);
          expect(jest.getTimerCount()).toBe(0);
          setTimeout(() => { throw new Error('stale timeout'); }, 3_600_000);
          setInterval(() => { throw new Error('stale interval'); }, 3_600_000);
          const signal = AbortSignal.timeout(3_600_000);
          signal.addEventListener('abort', () => { throw new Error('stale fake abort'); });
        `
      writeFileSync(join(isolated, i + '.test.js'), prelude + `
        import { jest } from 'bun:test';
        import { heapStats } from 'bun:jsc';
        import fs from 'node:fs';
        expect(globalThis.previousIsolatedFile).toBeUndefined();
        globalThis.previousIsolatedFile = ${i};
        ${leak}
        test('isolated ${mode} ${i}', () => {
          Bun.gc(true); Bun.gc(true);
          const count = heapStats().objectTypeCounts.GlobalObject;
          expect(count).toBeGreaterThan(0);
          expect(count).toBeLessThanOrEqual(4);
          console.log('ISOLATED:${i}:' + count);
        });
      `)
    }
    const result = invoke([isolated, '--isolate'])
    passed(result, 8)
    const samples = [...result.stdout.matchAll(/ISOLATED:(\d+):(\d+)/g)]
    assert.equal(samples.length, 8)
    assert.deepEqual(samples.map(sample => Number(sample[1])).sort(), [0, 1, 2, 3, 4, 5, 6, 7])
  }

  // Corpus files requiring native APIs use the same coordinator and complete
  // journal contract as other original files. Child native-VM dispatch remains
  // explicit so that nested test invocations cannot recurse into coordination.
  for (const [file, count] of [
    ['js/bun/sqlite/column-types.test.js', 9],
    ['js/bun/sqlite/sql-timezone.test.js', 2],
  ]) {
    const report = join(directory, 'corpus-' + count)
    const original = join(import.meta.dir, '../../packages/runtime/test/test', file)
    const corpusEnv = { ...process.env, HOME_BUN_CORPUS_REPORT_DIR: report, BUN_DEBUG_QUIET_LOGS: '1' }
    delete corpusEnv.HOME_NATIVE_VM
    delete corpusEnv.HOME_CORPUS_FULL_VM
    delete corpusEnv.HOME_NATIVE_RUN
    const result = spawnSync(process.execPath, ['test', original], {
      cwd: join(import.meta.dir, '../..'),
      env: corpusEnv,
      encoding: 'utf8', timeout: 30000,
    })
    assert.equal(result.status, 0, result.stdout + result.stderr)
    const rows = readFileSync(join(report, 'events.jsonl'), 'utf8').trim().split('\n').map(row => JSON.parse(row))
    assert.equal(rows.filter(row => row.event === 'selected' && row.path === file).length, 1)
    const completed = rows.find(row => row.event === 'completed')
    assert.equal(completed.source_unchanged, true)
    assert.equal(completed.output_complete, true)
    const finished = rows.at(-1)
    assert.equal(finished.event, 'finished')
    assert.equal(finished.summary.files, 1)
    assert.equal(finished.summary.passed, count)
    assert.equal(finished.summary.failed, 0)
    assert.equal(finished.summary.failed_files, 0)
  }
  console.log('native test CLI option and isolation regressions passed')
} finally {
  rmSync(directory, { recursive: true })
}
for (const pending of [false, true]) {
  const chunks = ['first', new Uint8Array([45, 115, 101, 99, 111, 110, 100])]
  const source = {
    [Symbol.asyncIterator]() {
      let index = 0
      return {
        next() {
          const result = index < chunks.length ? { value: chunks[index++], done: false } : { done: true }
          if (!pending) return Promise.resolve(result)
          return new Promise(resolve => queueMicrotask(() => resolve(result)))
        },
      }
    },
  }
  assert.equal(await new Response(source).text(), 'first-second')
}
const iteratorError = new Error('native async iterator rejection')
const rejectedSource = { [Symbol.asyncIterator]() { return { next() { return Promise.reject(iteratorError) } } } }
await assert.rejects(new Response(rejectedSource).text(), error => error === iteratorError)
console.log('native fulfilled, pending and rejected iterator promise controls passed')
console.log('native node core CLI regressions passed')
