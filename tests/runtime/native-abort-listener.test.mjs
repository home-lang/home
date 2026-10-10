import assert from 'node:assert/strict'
import { addAbortListener } from 'node:events'

for (const capture of [false, true]) {
  const controller = new AbortController()
  const calls = []
  controller.signal.addEventListener('abort', event => {
    calls.push('stop')
    event.stopImmediatePropagation()
  }, { capture })
  controller.signal.addEventListener('abort', () => calls.push('ordinary'))
  const first = addAbortListener(controller.signal, event => {
    assert.equal(event.target, controller.signal)
    calls.push('first')
  })
  addAbortListener(controller.signal, () => calls.push('second'))
  const disposed = addAbortListener(controller.signal, () => calls.push('disposed'))
  disposed[Symbol.dispose]()
  disposed[Symbol.dispose]()
  controller.abort()
  controller.signal.dispatchEvent(new Event('abort'))
  assert.deepEqual(calls, ['stop', 'first', 'second', 'stop'])
  first[Symbol.dispose]()
}

const controller = new AbortController()
const calls = []
controller.signal.addEventListener('abort', event => event.stopImmediatePropagation())
for (let index = 0; index < 10000; index++) {
  const disposable = addAbortListener(controller.signal, () => calls.push('removed'))
  disposable[Symbol.dispose]()
}
addAbortListener(controller.signal, () => calls.push('live'))
controller.abort()
assert.deepEqual(calls, ['live'])

const alreadyAborted = []
addAbortListener(AbortSignal.abort(), () => alreadyAborted.push('callback'))
assert.deepEqual(alreadyAborted, [])
await Promise.resolve()
assert.deepEqual(alreadyAborted, ['callback'])

const ordinaryTarget = new EventTarget()
const ordinary = []
ordinaryTarget.addEventListener('event', event => {
  ordinary.push('first')
  event.stopImmediatePropagation()
})
ordinaryTarget.addEventListener('event', () => ordinary.push('second'))
ordinaryTarget.dispatchEvent(new Event('event'))
assert.deepEqual(ordinary, ['first'])
console.log('native abort-listener propagation, disposal and ordinary dispatch passed')
