import assert from 'node:assert/strict'
import vm from 'node:vm'
import { spawnSync } from 'node:child_process'
import { Worker } from 'node:worker_threads'

function bounds(range) {
  assert.equal(typeof range.jsMemoryEstimate, 'number')
  assert(range.jsMemoryEstimate >= 0)
  assert(range.jsMemoryRange[0] <= range.jsMemoryEstimate)
  assert(range.jsMemoryEstimate <= range.jsMemoryRange[1])
}

async function main() {
  const small = vm.createContext({})
  const large = vm.createContext({})
  vm.runInContext('globalThis.payload = new Array(2000).fill(7)', small)
  vm.runInContext('globalThis.payload = new Array(8000).fill(11)', large)
  const result = await vm.measureMemory({ mode: 'detailed', execution: 'eager' })
  bounds(result.total)
  bounds(result.current)
  assert.equal(result.other.length, 2)
  for (const range of result.other) bounds(range)
  const sizes = result.other.map(range => range.jsMemoryEstimate).sort((a, b) => a - b)
  assert(sizes[1] > sizes[0] + 10000, JSON.stringify(result))
  assert(result.other.every(range => range.jsMemoryEstimate < result.total.jsMemoryEstimate))
  assert.equal(small.payload.length, 2000)
  assert.equal(large.payload.length, 8000)

  const collect = () => Bun.gc(true)
  const pending = vm.measureMemory({ mode: 'detailed' })
  collect()
  assert.equal((await pending).other.length, 2)
  const overlap = [
    vm.measureMemory({ execution: 'eager' }),
    vm.measureMemory({ mode: 'detailed', execution: 'eager' }),
    vm.measureMemory(),
  ]
  collect()
  for (const measurement of await Promise.all(overlap)) bounds(measurement.total)

  const child = spawnSync(process.execPath, ['-e', "require('node:vm').measureMemory(); process.exit(0)"], {
    encoding: 'utf8',
    timeout: 10000,
    env: { ...process.env, BUN_DESTRUCT_VM_ON_EXIT: '1' },
  })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  assert.equal(child.status, 0, child.stderr)
  const worker = new Worker(`
    const { parentPort } = require('node:worker_threads');
    require('node:vm').measureMemory();
    parentPort.on('message', () => {});
    parentPort.postMessage('pending');
  `, { eval: true })
  await new Promise((resolve, reject) => {
    worker.once('message', resolve)
    worker.once('error', reject)
  })
  assert.equal(typeof await worker.terminate(), 'number')
}
main().catch(error => { throw error })
