import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { Worker } from 'node:worker_threads'
import { monitorEventLoopDelay, performance as nodePerformance } from 'node:perf_hooks'

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
  assert.match(result.stdout, /all enabled monitors collected/)
  assert.equal(result.status, 0, result.stderr)
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
