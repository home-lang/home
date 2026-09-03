import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { Worker } from 'node:worker_threads'

assert.match(basename(process.execPath), /^home(?:-(?:debug|release-(?:safe|fast|small)))?(?:\.exe)?$/)

async function withDeadline(label, promise) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(new Error(`${label}: timed out`)), 5_000)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

async function naturalExit(code) {
  const worker = new Worker(`process.exit(${code})`, { eval: true })
  const observed = await withDeadline(
    `worker exit ${code}`,
    new Promise((resolve, reject) => {
      worker.once('exit', resolve)
      worker.once('error', reject)
    }),
  )
  assert.equal(observed, code)

  const expected = code === 0 ? undefined : code
  assert.equal(await withDeadline(`first terminate after exit ${code}`, worker.terminate()), expected)
  assert.equal(await withDeadline(`second terminate after exit ${code}`, worker.terminate()), expected)
}

await naturalExit(0)
await naturalExit(2)

const running = new Worker('setInterval(() => {}, 1_000)', { eval: true })
const first = running.terminate()
const second = running.terminate()
assert.equal(first, second, 'concurrent terminate calls must share their completion promise')
const terminatedCode = await withDeadline('concurrent terminate', first)
assert.ok(terminatedCode === 0 || terminatedCode === 1)
assert.equal(
  await withDeadline('terminate after forced exit', running.terminate()),
  terminatedCode === 0 ? undefined : terminatedCode,
)

console.log('native worker terminate-after-exit: PASS')
