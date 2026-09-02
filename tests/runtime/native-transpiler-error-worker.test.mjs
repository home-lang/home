import assert from 'node:assert/strict'
import { once } from 'node:events'
import { Worker } from 'node:worker_threads'

const withTimeout = async (promise, label) => {
  let timeout
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`${label} timeout`)), 15_000)
      }),
    ])
  } finally {
    clearTimeout(timeout)
  }
}

await assert.rejects(new Bun.Transpiler().transform('const ='))

const worker = new Worker(
  `
    const { parentPort } = require('node:worker_threads');
    const source = 'export default "' + 'x'.repeat(16 * 1024 * 1024) + '"';
    new Bun.Transpiler().transform(source).then(output => {
      parentPort.postMessage({ length: output.length, suffix: output.slice(-4) });
    });
  `,
  { eval: true },
)

try {
  const [result] = await withTimeout(once(worker, 'message'), 'worker transform')
  assert.ok(result.length > 16 * 1024 * 1024)
  assert.equal(result.suffix, 'x";\n')
} finally {
  await withTimeout(worker.terminate(), 'worker termination')
}

console.log('native transpiler error isolation passed')
