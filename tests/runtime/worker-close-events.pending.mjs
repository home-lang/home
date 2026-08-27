// Known native lifecycle gap: https://github.com/home-lang/home/issues/462.
// This executable regression intentionally fails until close events are ported;
// it is not a skipped test or evidence that worker_threads is fully supported.
import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { MessageChannel, receiveMessageOnPort } from 'node:worker_threads'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const { port1, port2 } = new MessageChannel()
const events = []
let timer
let returnedFromClose = false
try {
  const closed = new Promise((resolve, reject) => {
    timer = setTimeout(() => reject(new Error(`MessagePort close events missing: ${JSON.stringify(events)}`)), 5000)
    for (const [name, port] of [['port1', port1], ['port2', port2]]) {
      port.on('close', () => {
        try {
          assert.equal(returnedFromClose, true, 'close events must be asynchronous')
          assert.equal(events.includes(name), false, 'each endpoint closes exactly once')
          events.push(name)
          if (events.length === 2) resolve()
        } catch (error) {
          reject(error)
        }
      })
    }
  })
  port1.postMessage('queued before close')
  // Closing one endpoint must notify both, even without message listeners or
  // start(). Repeated explicit closes must not enqueue duplicate events.
  port2.close()
  port2.close()
  assert.deepEqual(events, [])
  returnedFromClose = true
  await closed
  assert.deepEqual([...events].sort(), ['port1', 'port2'])
  assert.equal(receiveMessageOnPort(port1), undefined)
  assert.equal(receiveMessageOnPort(port2), undefined)
  port1.close()
  port2.close()
  await new Promise(resolve => setImmediate(resolve))
  assert.deepEqual([...events].sort(), ['port1', 'port2'])
} finally {
  clearTimeout(timer)
  port1.close()
  port2.close()
}
console.log('native worker close-event regressions passed')
