import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-native-corpus-outcomes-'))
const project = join(directory, 'packages/runtime/test')
const root = join(project, 'test')
const nodeRoot = join(root, 'js/node/test/parallel')
mkdirSync(nodeRoot, { recursive: true })
mkdirSync(join(root, 'js/bun/test'), { recursive: true })
writeFileSync(join(project, 'bunfig.toml'), '[test]\n')
writeFileSync(join(project, 'bunfig.node-test.toml'), '[test]\n[install]\nauto = "disable"\n')
const env = { ...process.env, NO_COLOR: '1' }
delete env.HOME_NATIVE_VM
delete env.HOME_CORPUS_FULL_VM
const reports = []
const sources = new Map()
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
function fixture(relative, source) {
  const path = join(root, relative)
  writeFileSync(path, source)
  sources.set(path, hash(readFileSync(path)))
  return path
}
function events(report) {
  return readFileSync(join(report, 'events.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
}
function start(name, paths, report = join(directory, `report-${name}`)) {
  if (!reports.includes(report)) reports.push(report)
  const child = Bun.spawn([process.execPath, 'test', ...paths], {
    cwd: directory, env: { ...env, HOME_BUN_CORPUS_REPORT_DIR: report, TMPDIR: directory },
    stdin: 'ignore', stdout: 'pipe', stderr: 'pipe',
  })
  const stdout = new Response(child.stdout).text()
  const stderr = new Response(child.stderr).text()
  return { child, report, async finish() {
    const timer = setTimeout(() => child.kill('SIGKILL'), 60000)
    try { return { code: await child.exited, stdout: await stdout, stderr: await stderr, report } }
    finally { clearTimeout(timer) }
  } }
}
function complete(report, expectedFiles) {
  const rows = events(report)
  assert.equal(rows[0].event, 'run')
  const selected = rows.filter(row => row.event === 'selected')
  const started = rows.filter(row => row.event === 'started')
  const completed = rows.filter(row => row.event === 'completed')
  assert.equal(selected.length, expectedFiles)
  assert.equal(started.length, expectedFiles)
  assert.equal(completed.length, expectedFiles)
  assert(rows.slice(1, expectedFiles + 1).every(row => row.event === 'selected'), 'select the whole run before executing anything')
  assert.equal(rows.at(-1).event, 'finished')
  assert.equal(rows.at(-1).all_selected_completed, true)
  for (const row of completed) {
    for (const stream of ['stdout', 'stderr']) assert.equal(hash(readFileSync(join(report, row[`${stream}_file`]))), row[`${stream}_sha256`])
    assert.equal(row.source_unchanged, true)
    assert.equal(row.output_complete, true)
    if (row.junit === 'retained') assert.equal(hash(readFileSync(join(report, row.junit_file))), row.junit_sha256)
  }
  return { rows, started, completed, summary: rows.at(-1).summary }
}
try {
  const mixed = fixture('mixed.test.js', `import { test, expect } from 'bun:test';
    test('passing case', () => expect(1).toBe(1));
    test('failing case', () => expect(1).toBe(2));
    test.skip('skipped case', () => { throw new Error('must not execute'); });
    test.todo('todo case');`)
  const manual = fixture('manual.test.js', "require('node:assert').strictEqual(4, 2 + 2); console.log('manual body executed')")
  const empty = fixture('empty.test.js', '// intentionally empty\n')
  const run = await start('mixed', [mixed, manual, empty]).finish()
  assert.equal(run.code, 1, run.stderr)
  const result = complete(run.report, 3)
  for (const key of ['passed', 'failed', 'skipped', 'todo', 'failed_files', 'process_checks_passed', 'comment_only_files']) assert.equal(result.summary[key], 1, key)
  const xml = readFileSync(join(run.report, result.completed[0].junit_file), 'utf8')
  assert.equal((xml.match(/<testcase\s/g) || []).length, 4)
  for (const text of ['passing case', 'failing case', 'skipped case', 'todo case', '<failure', '<skipped', 'TODO']) assert(xml.includes(text), text)
  assert.equal(result.started[0].timeout_ms, 180000)
  assert(result.started[0].argv.includes('--reporter=junit'))
  assert.equal(result.started[0].environment.BUN_GARBAGE_COLLECTOR_LEVEL, '1')
  assert.equal(result.started[0].executable_sha256, hash(readFileSync(process.execPath)))
  console.log('mixed outcomes: pass=1 fail=1 skip=1 todo=1 process=1 empty=1')

  const originalJournal = hash(readFileSync(join(run.report, 'events.jsonl')))
  const sideEffect = join(directory, 'must-not-execute')
  const never = fixture('never.test.js', `require('node:fs').writeFileSync(${JSON.stringify(sideEffect)}, 'bad')`)
  const refused = await start('overwrite', [never], run.report).finish()
  assert.notEqual(refused.code, 0)
  assert.equal(existsSync(sideEffect), false)
  assert.equal(hash(readFileSync(join(run.report, 'events.jsonl'))), originalJournal)
  console.log('existing report directory refused before fixture execution')

  const scriptFailure = fixture('js/node/test/parallel/test-journal-failure.js', "require('node:assert').strictEqual(1, 2, 'real script failure')")
  const failed = await start('script-failure', [scriptFailure]).finish()
  assert.notEqual(failed.code, 0)
  const failedResult = complete(failed.report, 1)
  assert.equal(failedResult.summary.failed_files, 1)
  assert.equal(failedResult.summary.passed + failedResult.summary.failed, 0)
  assert.equal(failedResult.completed[0].junit, 'not_requested')
  assert(!failedResult.started[0].argv.includes('--reporter=junit'))
  console.log('script assertion failure retained without invented cases')

  const invalidNegative = fixture('js/bun/test/test-fixture-diff-indexed-properties.js', "import { test, expect } from 'bun:test'; test('invalid negative contract', () => expect(1).toBe(2))")
  const rejectedNegative = await start('invalid-negative', [invalidNegative]).finish()
  assert.notEqual(rejectedNegative.code, 0)
  const rejectedResult = complete(rejectedNegative.report, 1)
  assert.equal(rejectedResult.completed[0].expected_failure_verified, false)
  assert.equal(rejectedResult.completed[0].counts.failed, 1)
  assert.equal(rejectedResult.summary.failed, 1, 'an unverified negative fixture must retain its actual failing case')
  assert.equal(rejectedResult.summary.failed_files, 1)
  assert.equal(rejectedResult.summary.process_checks_passed, 0)
  console.log('invalid negative contract retains its real failing case')

  const timeout = fixture('js/node/test/parallel/test-journal-timeout.js', "console.log('timeout body entered'); setInterval(() => {}, 1000)")
  const timed = await start('timeout', [timeout]).finish()
  assert.notEqual(timed.code, 0)
  const timedResult = complete(timed.report, 1)
  assert.equal(timedResult.started[0].timeout_ms, 20000)
  assert.equal(timedResult.completed[0].timed_out, true)
  assert.equal(timedResult.summary.failed_files, 1)
  assert.equal(timedResult.summary.passed + timedResult.summary.failed, 0)
  console.log('actual 20-second Node deadline retained')

  if (process.platform === 'darwin') {
    // fs.closeSync deliberately preserves standard descriptors in pinned Bun.
    // Use actual libc close through the production FFI to establish pipe EOF.
    const closedReady = join(directory, 'libc-close-results')
    const closeSource = `import { dlopen } from 'bun:ffi'; const fs = require('node:fs');
      const library = dlopen('/usr/lib/libSystem.B.dylib', { close: { args: ['i32'], returns: 'i32' } });
      const results = [library.symbols.close(1), library.symbols.close(2)];
      fs.writeFileSync(${JSON.stringify(closedReady)}, JSON.stringify(results));`
    const closedSuccess = fixture('js/node/test/parallel/test-journal-closed-success.js', closeSource + 'setTimeout(() => process.exit(0), 50)')
    const earlyExit = await start('closed-success', [closedSuccess]).finish()
    assert.equal(earlyExit.code, 0)
    assert.deepEqual(JSON.parse(readFileSync(closedReady, 'utf8')), [0, 0])
    const earlyResult = complete(earlyExit.report, 1)
    assert.equal(earlyResult.completed[0].timed_out, false)
    assert.equal(earlyResult.summary.process_checks_passed, 1)
    assert.equal(earlyResult.summary.passed, 0)
    rmSync(closedReady)
    const closedTimeout = fixture('js/node/test/parallel/test-journal-closed-timeout.js', closeSource + 'setInterval(() => {}, 1000)')
    const pastEof = await start('closed-timeout', [closedTimeout]).finish()
    assert.notEqual(pastEof.code, 0)
    assert.deepEqual(JSON.parse(readFileSync(closedReady, 'utf8')), [0, 0])
    const eofResult = complete(pastEof.report, 1)
    assert.equal(eofResult.started[0].timeout_ms, 20000)
    assert.equal(eofResult.completed[0].timed_out, true)
    assert.equal(eofResult.summary.failed_files, 1)
    console.log('real libc EOF preserves early exit and the actual 20-second child deadline')
  }

  const signal = fixture('js/node/test/parallel/test-journal-signal.js', "console.log('signal body entered'); process.kill(process.pid, 'SIGTERM')")
  const signaled = await start('signal', [signal]).finish()
  assert.notEqual(signaled.code, 0)
  const signalResult = complete(signaled.report, 1)
  assert.equal(signalResult.completed[0].timed_out, false)
  assert.equal(signalResult.completed[0].term.signal, 'TERM')
  console.log('real SIGTERM retained separately from timeout')

  const readiness = join(directory, 'interrupt-ready')
  const interrupt = fixture('js/node/test/parallel/test-journal-interrupt.js', `require('node:fs').writeFileSync(${JSON.stringify(readiness)}, String(process.pid)); setInterval(() => {}, 1000)`)
  const running = start('interruption', [interrupt, never])
  let childPid
  try {
    const deadline = Date.now() + 15000
    while (!existsSync(readiness) && Date.now() < deadline) await Bun.sleep(20)
    assert(existsSync(readiness), 'own child must enter fixture before interrupting its runner')
    childPid = Number(readFileSync(readiness, 'utf8'))
    assert(Number.isSafeInteger(childPid) && childPid > 1)
    running.child.kill('SIGKILL')
    await running.finish()
  } finally {
    running.child.kill('SIGKILL')
    if (childPid) {
      try { process.kill(childPid, 'SIGTERM') } catch (error) { if (error.code !== 'ESRCH') throw error }
    }
  }
  const interrupted = events(running.report)
  assert.equal(interrupted.filter(row => row.event === 'selected').length, 2)
  assert.equal(interrupted.filter(row => row.event === 'started').length, 1)
  assert.equal(interrupted.filter(row => row.event === 'completed').length, 0)
  assert.equal(interrupted.filter(row => row.event === 'finished').length, 0)
  assert.equal(existsSync(sideEffect), false)
  console.log('interruption retains one incomplete and one unstarted selection')

  // Prevent capture persistence using an actual conflicting artifact. The
  // runner must fail and leave an incomplete journal, never claim completion.
  const writeFailure = fixture('js/node/test/parallel/test-journal-write-failure.js', `require('node:fs').mkdirSync(require('node:path').join(process.env.HOME_BUN_CORPUS_REPORT_DIR, '000000.stdout')); console.log('real write failure')`)
  const unwritable = await start('write-failure', [writeFailure]).finish()
  assert.notEqual(unwritable.code, 0)
  const writeRows = events(unwritable.report)
  assert.equal(writeRows.filter(row => row.event === 'started').length, 1)
  assert.equal(writeRows.filter(row => row.event === 'completed' || row.event === 'finished').length, 0)
  console.log('failed artifact write leaves execution incomplete')

  for (const [path, before] of sources) assert.equal(hash(readFileSync(path)), before, path)
  console.log('all fixture source hashes unchanged')
} finally {
  if (process.env.HOME_CORPUS_EVIDENCE_DIR) {
    const destination = process.env.HOME_CORPUS_EVIDENCE_DIR
    mkdirSync(destination) // Exclusive evidence namespace; never reuse a run.
    for (const report of reports) if (existsSync(report)) cpSync(report, join(destination, basename(report)), { recursive: true, errorOnExist: true, force: false })
  }
  rmSync(directory, { recursive: true, force: true })
}
