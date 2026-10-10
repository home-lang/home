import assert from 'node:assert/strict'
import { monitorEventLoopDelay } from 'node:perf_hooks'

const resolution = Number(process.argv[2])
function make() {
  const histogram = monitorEventLoopDelay({ resolution })
  histogram.enable()
  return new WeakRef(histogram)
}
const references = Array.from({ length: 20 }, make)
for (let attempt = 0; attempt < 20; attempt++) {
  await new Promise(resolve => setTimeout(resolve, 2))
  Bun.gc(true)
}
assert(references.every(reference => reference.deref() === undefined))
console.log('all enabled monitors collected')
