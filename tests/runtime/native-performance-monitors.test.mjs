import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { Worker } from 'node:worker_threads'
import { createHistogram, monitorEventLoopDelay, PerformanceEntry, PerformanceNodeTiming, performance as nodePerformance } from 'node:perf_hooks'

async function waitFor(condition) {
  const deadline = Date.now() + 2000
  while (!condition()) {
    assert(Date.now() < deadline, 'monitor did not publish expected samples')
    await new Promise(resolve => setTimeout(resolve, 2))
  }
}

const first = monitorEventLoopDelay({ resolution: 1 })
const second = monitorEventLoopDelay({ resolution: 2 })
assert.notEqual(first, second)
assert.equal(first.enable(), true)
assert.equal(first.enable(), false)
assert.equal(second.enable(), true)
assert.equal(second.enable(), false)
await waitFor(() => first.count > 0 && second.count > 0)
assert(first.count > 0)
assert(second.count > 0)
assert(first.min > 0)
assert(second.min > 0)
assert.equal(first.disable(), true)
assert.equal(first.disable(), false)
const firstCount = first.count
const secondCount = second.count
await waitFor(() => second.count > secondCount)
assert.equal(first.count, firstCount)
assert(second.count > secondCount)
assert.equal(first.enable(), true)
assert.equal(first.count, firstCount)
await waitFor(() => first.count > firstCount)
assert(first.count > firstCount)
assert.equal(first[Symbol.dispose](), true)
assert.equal(second[Symbol.dispose](), true)
assert.equal(second.disable(), false)

const large = monitorEventLoopDelay({ resolution: Number.MAX_SAFE_INTEGER })
assert.equal(large.enable(), true)
assert.equal(large.disable(), true)
assert.throws(() => monitorEventLoopDelay({ resolution: null }), { code: 'ERR_INVALID_ARG_TYPE' })
assert.throws(() => monitorEventLoopDelay({ resolution: 0 }), { code: 'ERR_OUT_OF_RANGE' })

// Isolate GC creation scopes from the live sampling checks above. Native
// weak ownership must permit collection at both short and long resolutions.
for (const resolution of [1, Number.MAX_SAFE_INTEGER]) {
  const result = spawnSync(process.execPath, ['run', join(import.meta.dir, 'native-performance-monitors-gc.fixture.mjs'), String(resolution)], {
    env: { ...process.env, BUN_DEBUG_QUIET_LOGS: '1' }, encoding: 'utf8', timeout: 10000,
  })
  assert.equal(result.status, 0, JSON.stringify({ status: result.status, signal: result.signal, error: result.error?.message, stdout: result.stdout, stderr: result.stderr }))
  assert.match(result.stdout, /all enabled monitors collected/)
}
const unreferenced = spawnSync(process.execPath, ['-e', `
  const { monitorEventLoopDelay } = require('node:perf_hooks');
  monitorEventLoopDelay({ resolution: 1 }).enable();
  console.log('enabled monitor does not keep the process alive');
`], { env: { ...process.env, BUN_DEBUG_QUIET_LOGS: '1' }, encoding: 'utf8', timeout: 10000 })
assert.match(unreferenced.stdout, /enabled monitor does not keep the process alive/)
assert.equal(unreferenced.status, 0, unreferenced.stderr)
await new Promise((resolve, reject) => {
  const worker = new Worker(`
    const { monitorEventLoopDelay } = require('node:perf_hooks');
    monitorEventLoopDelay({ resolution: 1 }).enable();
  `, { eval: true })
  worker.once('error', reject)
  worker.once('exit', code => {
    try { assert.equal(code, 0); resolve() } catch (error) { reject(error) }
  })
})
assert.equal(typeof nodePerformance.clearResourceTimings, 'function')
nodePerformance.clearResourceTimings()
console.log('native independent delay monitors, weak lifetime, retained samples and large resolution passed')

// Bounds are validated before entering HDR, and BigInts retain all 64 bits.
for (const options of [null, false, 1, 'options', []]) {
  assert.throws(() => createHistogram(options), { code: 'ERR_INVALID_ARG_TYPE' })
}
for (const name of ['lowest', 'highest', 'figures']) {
  for (const value of [NaN, Infinity, 1.5, 0, -1]) {
    assert.throws(() => createHistogram({ [name]: value }), { code: 'ERR_OUT_OF_RANGE' })
  }
}
for (const name of ['lowest', 'highest']) {
  assert.throws(() => createHistogram({ [name]: Number.MAX_SAFE_INTEGER + 1 }), { code: 'ERR_OUT_OF_RANGE' })
  assert.throws(() => createHistogram({ [name]: 9223372036854775808n }), { code: 'ERR_OUT_OF_RANGE' })
}
assert.throws(() => createHistogram({ lowest: 4503599627370497n, highest: 9007199254740993n }), { code: 'ERR_OUT_OF_RANGE' })
const precise = createHistogram({ lowest: 1n, highest: 9223372036854775807n, figures: 1 })
precise.record(1n)
precise.record(9007199254740993n)
assert.equal(precise.countBigInt, 2n)
assert.equal(precise.maxBigInt, 9007199254740993n)
assert.equal(precise.exceedsBigInt, 0n)
const smallBigInts = createHistogram({ lowest: 1n, highest: 10n, figures: 1 })
smallBigInts.record(5n)
assert.equal(smallBigInts.minBigInt, 5n)
console.log('native histogram integer validation and exact BigInt transport passed')
let optionReads = 0
createHistogram({ get lowest() { optionReads++; return 1n }, get highest() { optionReads++; return 10n }, get figures() { optionReads++; return 1 } })
assert.equal(optionReads, 3)

const records = createHistogram()
for (const value of [0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, 0n, -1n, 9223372036854775808n, 18446744073709551617n]) {
  assert.throws(() => records.record(value), { code: 'ERR_OUT_OF_RANGE' })
  assert.equal(records.countBigInt, 0n)
  assert.equal(records.exceedsBigInt, 0n)
}
for (const value of [undefined, null, '1', true, {}]) {
  assert.throws(() => records.record(value), { code: 'ERR_INVALID_ARG_TYPE' })
}
assert.throws(() => records.record(), { code: 'ERR_INVALID_ARG_TYPE' })
records.record(1n)
records.record(9223372036854775807n)
assert.equal(records.countBigInt, 1n)
assert.equal(records.exceedsBigInt, 1n)
const direct = new records.constructor(1n, 10n, 1)
direct.record(5n)
assert.equal(direct.minBigInt, 5n)
console.log('native histogram recording validates before conversion and preserves counters')

const beforeIdle = nodePerformance.eventLoopUtilization()
await new Promise(resolve => setTimeout(resolve, 30))
const afterIdle = nodePerformance.eventLoopUtilization()
assert(afterIdle.idle > beforeIdle.idle)
const idleDelta = nodePerformance.eventLoopUtilization(afterIdle, beforeIdle)
assert(idleDelta.idle > 0)
assert.equal(idleDelta.idle, afterIdle.idle - beforeIdle.idle)
assert.equal(idleDelta.active, afterIdle.active - beforeIdle.active)
const beforeBusy = nodePerformance.eventLoopUtilization()
const busyUntil = performance.now() + 20
while (performance.now() < busyUntil) {}
const busyDelta = nodePerformance.eventLoopUtilization(beforeBusy)
assert(busyDelta.active >= 15)
assert.equal(busyDelta.idle, 0)
assert.equal(busyDelta.utilization, 1)
assert(Number.isNaN(nodePerformance.eventLoopUtilization(afterIdle, afterIdle).utilization))
console.log('native measured event-loop idle/active counters and snapshot deltas passed')
await new Promise((resolve, reject) => {
  const worker = new Worker(`
    const { parentPort } = require('node:worker_threads');
    const { performance: perf } = require('node:perf_hooks');
    setTimeout(() => {
      const before = perf.eventLoopUtilization();
      const until = performance.now() + 20;
      while (performance.now() < until) {}
      parentPort.postMessage(perf.eventLoopUtilization(before));
    }, 10);
  `, { eval: true })
  let received = false
  worker.once('error', reject)
  worker.once('message', delta => {
    received = true
    try { assert(delta.active >= 15); assert.equal(delta.idle, 0); assert.equal(delta.utilization, 1) } catch (error) { reject(error) }
  })
  worker.once('exit', code => {
    try { assert.equal(code, 0); assert.equal(received, true); resolve() } catch (error) { reject(error) }
  })
})
console.log('native worker-local utilization counters passed')

const timing = nodePerformance.nodeTiming
assert(timing instanceof PerformanceEntry)
assert(timing instanceof PerformanceNodeTiming)
assert.throws(() => new PerformanceNodeTiming(), TypeError)
assert.equal(timing.startTime, 0)
assert.equal(timing.nodeStart, 0)
assert(timing.v8Start >= 0)
assert(timing.environment >= timing.v8Start)
assert(timing.bootstrapComplete >= timing.environment)
assert(timing.bootstrapComplete <= performance.now())
assert(timing.loopStart >= 0)
assert.equal(timing.loopExit, -1)
const idleTime = timing.idleTime
await new Promise(resolve => setTimeout(resolve, 20))
assert(timing.idleTime > idleTime)
const timingJSON = timing.toJSON()
assert.equal(timingJSON.name, 'node')
assert.equal(timingJSON.entryType, 'node')
assert.equal(timingJSON.bootstrapComplete, timing.bootstrapComplete)
assert.equal(timingJSON.environment, timing.environment)
assert(timingJSON.duration >= timingJSON.bootstrapComplete)
const exitTiming = spawnSync(process.execPath, ['-e', `
  const { performance: perf } = require('node:perf_hooks');
  setTimeout(() => {}, 1);
  process.on('exit', () => console.log(JSON.stringify(perf.nodeTiming.toJSON())));
`], { env: { ...process.env, BUN_DEBUG_QUIET_LOGS: '1' }, encoding: 'utf8', timeout: 10000 })
assert.equal(exitTiming.status, 0, exitTiming.stderr)
const exited = JSON.parse(exitTiming.stdout.trim())
assert(exited.loopExit >= exited.loopStart)
assert(exited.loopExit <= exited.duration)
assert(exited.loopStart >= 0)
console.log('native startup milestones, live idle timing, serialization and loop exit passed')
const explicitExitTiming = spawnSync(process.execPath, ['-e', `
  const { performance: perf } = require('node:perf_hooks');
  process.on('exit', () => console.log(JSON.stringify(perf.nodeTiming.toJSON())));
  setTimeout(() => process.exit(0), 1);
`], { env: { ...process.env, BUN_DEBUG_QUIET_LOGS: '1' }, encoding: 'utf8', timeout: 10000 })
assert.equal(explicitExitTiming.status, 0, explicitExitTiming.stderr)
const explicitExit = JSON.parse(explicitExitTiming.stdout.trim())
assert(explicitExit.loopExit >= explicitExit.loopStart)
assert(explicitExit.loopExit <= explicitExit.duration)
