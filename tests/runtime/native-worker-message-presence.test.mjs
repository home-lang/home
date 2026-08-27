import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { MessageChannel, MessagePort, Worker, isMainThread, parentPort, receiveMessageOnPort, threadId, workerData } from 'node:worker_threads'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const values = [undefined, null, false, true, 0, -0, NaN, '', 0n, 1n, 'value']

function take(port) {
  const envelope = receiveMessageOnPort(port)
  assert.notEqual(envelope, undefined, 'a queued message must not look like an empty queue')
  assert.equal(Object.getPrototypeOf(envelope), Object.prototype)
  assert.deepEqual(Reflect.ownKeys(envelope), ['message'])
  assert.deepEqual(Object.getOwnPropertyDescriptor(envelope, 'message'), {
    value: envelope.message,
    writable: true,
    enumerable: true,
    configurable: true,
  })
  return envelope.message
}

function checkSequence(port) {
  for (const value of values) assert.ok(Object.is(take(port), value), `FIFO payload ${String(value)}`)
  assert.equal(receiveMessageOnPort(port), undefined)
  assert.equal(receiveMessageOnPort(port), undefined)
}

function checkPresence() {
  const { port1, port2 } = new MessageChannel()
  const nested = new MessageChannel()
  let transferredPort
  try {
    assert.equal(receiveMessageOnPort(port2), undefined)
    for (const value of values) port1.postMessage(value)
    checkSequence(port2)

    // Native envelopes must define an own data property, not invoke a setter
    // inherited from user-controlled Object.prototype.
    const previous = Object.getOwnPropertyDescriptor(Object.prototype, 'message')
    try {
      Object.defineProperty(Object.prototype, 'message', {
        configurable: true,
        set() { throw new Error('inherited message setter was invoked') },
      })
      port1.postMessage(undefined)
      assert.equal(take(port2), undefined)
    } finally {
      if (previous) Object.defineProperty(Object.prototype, 'message', previous)
      else delete Object.prototype.message
    }

    const shared = { value: 'before' }
    const graph = { message: undefined, shared, alias: shared, map: new Map([[shared, shared]]), set: new Set([shared]) }
    graph.self = graph
    port1.postMessage(graph)
    shared.value = 'after'
    const cloned = take(port2)
    assert.notEqual(cloned, graph)
    assert.equal(cloned.message, undefined)
    assert.equal(Object.hasOwn(cloned, 'message'), true)
    assert.equal(cloned.self, cloned)
    assert.equal(cloned.shared, cloned.alias)
    assert.equal(cloned.shared.value, 'before')
    assert.equal(cloned.map.get(cloned.shared), cloned.shared)
    assert.equal(cloned.set.has(cloned.shared), true)

    const bytes = Uint8Array.from([0, 1, 127, 255])
    port1.postMessage({ bytes }, [bytes.buffer])
    assert.equal(bytes.buffer.byteLength, 0)
    assert.deepEqual(take(port2).bytes, Uint8Array.from([0, 1, 127, 255]))

    // Queued payloads survive transferring their port, and the old wrapper
    // cannot read the transferred queue anymore.
    nested.port1.postMessage(undefined)
    nested.port1.postMessage(false)
    port1.postMessage({ port: nested.port2 }, [nested.port2])
    transferredPort = take(port2).port
    assert.ok(transferredPort instanceof MessagePort)
    assert.equal(receiveMessageOnPort(nested.port2), undefined)
    assert.equal(take(transferredPort), undefined)
    assert.equal(take(transferredPort), false)
    nested.port1.postMessage(0n)
    assert.equal(take(transferredPort), 0n)
    assert.equal(receiveMessageOnPort(transferredPort), undefined)

    port1.postMessage('queued before close')
    port2.close()
    // Local close stops asynchronous delivery, but synchronous receive keeps
    // access to already accepted data until the close event completes.
    assert.equal(take(port2), 'queued before close')
    assert.equal(receiveMessageOnPort(port2), undefined)

    for (const invalid of [undefined, null, false, 0, '', {}, [], port1.constructor.prototype]) {
      assert.throws(() => receiveMessageOnPort(invalid), {
        name: 'TypeError',
        code: 'ERR_INVALID_ARG_TYPE',
      })
    }
  } finally {
    transferredPort?.close()
    nested.port1.close()
    nested.port2.close()
    port1.close()
    port2.close()
  }
}

async function checkEventConsumption() {
  const { port1, port2 } = new MessageChannel()
  let timer
  try {
    const seen = []
    const delivered = new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('message delivery timed out')), 5000)
      port2.on('message', value => {
        try {
          seen.push(value)
          if (value === 2) assert.equal(take(port2), 3)
          else {
            assert.equal(value, 4)
            assert.deepEqual(seen, [2, 4])
            assert.equal(receiveMessageOnPort(port2), undefined)
            resolve()
          }
        } catch (error) {
          reject(error)
        }
      })
    })
    for (const value of [1, 2, 3, 4]) port1.postMessage(value)
    assert.equal(take(port2), 1)
    await delivered
  } finally {
    clearTimeout(timer)
    port1.close()
    port2.close()
  }
}

checkPresence()
await checkEventConsumption()

if (isMainThread) {
  const channel = new MessageChannel()
  let worker
  let timer
  let exited = false
  try {
    for (const value of values) channel.port1.postMessage(value)
    worker = new Worker(new URL(import.meta.url), {
      workerData: { port: channel.port2 },
      transferList: [channel.port2],
    })
    assert.equal(receiveMessageOnPort(channel.port2), undefined)
    await new Promise((resolve, reject) => {
      let verified = false
      timer = setTimeout(() => reject(new Error('worker message regression timed out')), 10000)
      worker.on('message', message => {
        try {
          assert.equal(message.verified, true)
          assert.notEqual(message.threadId, threadId)
          assert.equal(verified, false)
          verified = true
        } catch (error) {
          reject(error)
        }
      })
      worker.on('error', reject)
      worker.on('exit', code => {
        exited = true
        try {
          assert.equal(code, 0)
          assert.equal(verified, true, 'worker must execute the same native queue regressions')
          resolve()
        } catch (error) {
          reject(error)
        }
      })
    })
  } finally {
    clearTimeout(timer)
    if (worker && !exited) await worker.terminate()
    channel.port1.close()
    channel.port2.close()
  }
  console.log('native worker message presence regressions passed')
} else {
  try {
    assert.ok(workerData.port instanceof MessagePort)
    checkSequence(workerData.port)
    parentPort.postMessage({ verified: true, threadId })
  } finally {
    workerData.port.close()
  }
}
