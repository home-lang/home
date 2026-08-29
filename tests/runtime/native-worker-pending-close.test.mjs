// Pending-close contracts for https://github.com/home-lang/home/issues/466.
// Node controls run this exact body with only the native Home guard removed.
import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { MessageChannel, MessagePort, receiveMessageOnPort } from 'node:worker_threads'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const turn = () => new Promise(resolve => setImmediate(resolve))

function take(port) {
  const result = receiveMessageOnPort(port)
  assert.notEqual(result, undefined, 'closing inbox must retain an accepted message')
  assert.equal(Object.hasOwn(result, 'message'), true)
  return result.message
}

function watchClose(port) {
  const calls = []
  let resolve
  const done = new Promise(complete => { resolve = complete })
  port.on('close', function (...args) {
    calls.push({ receiver: this, args })
    resolve()
  })
  return { calls, done }
}

// Node 24.18 can crash if receiveMessageOnPort is called inside a close
// callback or its immediate Promise continuation. Wait until close callbacks
// have fully unwound before checking the completed-close state.
async function afterClose(...observers) {
  await Promise.all(observers.map(observer => observer.done))
  await turn()
  for (const observer of observers) assert.equal(observer.calls.length, 1)
}

let passed = 0
async function check(name, body) {
  const ports = new Set()
  let timer
  const resources = {
    channel() {
      const channel = new MessageChannel()
      ports.add(channel.port1)
      ports.add(channel.port2)
      return channel
    },
    port(port) {
      assert.ok(port instanceof MessagePort)
      ports.add(port)
      return port
    },
  }
  try {
    await Promise.race([
      body(resources),
      new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(new Error(name + ': timed out')), 3000)
      }),
    ])
    passed++
    console.log('pass: ' + name)
  } finally {
    clearTimeout(timer)
    for (const port of ports) port.close()
  }
}

await check('pending local close retains every falsy payload in FIFO order', async ({ channel }) => {
  const { port1, port2 } = channel()
  const local = watchClose(port1)
  const peer = watchClose(port2)
  const values = [undefined, null, false, 0, -0, 0n, '', NaN, 'tail']
  const callbacks = []
  function callback(...args) { callbacks.push({ receiver: this, args }) }
  for (const value of values) port2.postMessage(value)
  port1.close(callback)
  port1.close(callback)
  assert.deepEqual(callbacks, [])
  assert.deepEqual(local.calls, [])
  for (const value of values) assert.ok(Object.is(take(port1), value))
  assert.equal(receiveMessageOnPort(port1), undefined)
  await afterClose(local, peer)
  assert.equal(callbacks.length, 1)
  assert.equal(callbacks[0].receiver, port1)
  assert.equal(callbacks[0].args.length, 1)
  assert.ok(callbacks[0].args[0] instanceof Event)
  assert.equal(callbacks[0].args[0].type, 'close')
  assert.equal(receiveMessageOnPort(port1), undefined)
  assert.equal(receiveMessageOnPort(port2), undefined)
})

await check('microtasks preserve pending inbox and peer sends but not local sends', async ({ channel }) => {
  const { port1, port2 } = channel()
  const local = watchClose(port1)
  const peer = watchClose(port2)
  port1.postMessage('accepted before close')
  port2.postMessage('already queued')
  port1.close()
  port1.postMessage('must not be delivered')
  port2.postMessage('sent after local close')
  assert.equal(take(port1), 'already queued')
  assert.equal(take(port2), 'accepted before close')
  assert.equal(receiveMessageOnPort(port2), undefined)
  await Promise.resolve()
  assert.deepEqual(local.calls, [])
  assert.equal(take(port1), 'sent after local close')
  await new Promise(resolve => queueMicrotask(resolve))
  assert.deepEqual(local.calls, [])
  port2.postMessage(undefined)
  assert.equal(take(port1), undefined)
  assert.equal(receiveMessageOnPort(port1), undefined)
  await afterClose(local, peer)
  assert.equal(receiveMessageOnPort(port1), undefined)
})

for (const mode of ['unstarted', 'start', 'onmessage', 'listener-before-close', 'listener-after-close']) {
  await check('closing inbox never asynchronously delivers: ' + mode, async ({ channel }) => {
    const { port1, port2 } = channel()
    const local = watchClose(port1)
    const peer = watchClose(port2)
    const seen = []
    if (mode === 'listener-before-close') port1.on('message', value => seen.push(value))
    port2.postMessage('synchronously consumed')
    port2.postMessage('discarded at close completion')
    port1.close()
    if (mode === 'start') port1.start()
    if (mode === 'onmessage') port1.onmessage = event => seen.push(event.data)
    if (mode === 'listener-after-close') port1.on('message', value => seen.push(value))
    assert.equal(take(port1), 'synchronously consumed')
    await Promise.resolve()
    assert.deepEqual(seen, [])
    await afterClose(local, peer)
    assert.deepEqual(seen, [])
    assert.equal(receiveMessageOnPort(port1), undefined)
  })
}

await check('a pending-closing port cannot be transferred but keeps its inbox', async ({ channel }) => {
  const pair = channel()
  const carrier = channel()
  const local = watchClose(pair.port1)
  const peer = watchClose(pair.port2)
  pair.port2.postMessage('preserved after rejected transfer')
  pair.port1.close()
  assert.throws(() => carrier.port1.postMessage(pair.port1, [pair.port1]), {
    name: 'DataCloneError', code: 25,
  })
  assert.equal(receiveMessageOnPort(carrier.port2), undefined)
  assert.equal(take(pair.port1), 'preserved after rejected transfer')
  await afterClose(local, peer)
  assert.throws(() => carrier.port1.postMessage(pair.port1, [pair.port1]), {
    name: 'DataCloneError', code: 25,
  })
  assert.equal(receiveMessageOnPort(carrier.port2), undefined)
})

await check('both locally closing endpoints retain their previously accepted inboxes', async ({ channel }) => {
  const { port1, port2 } = channel()
  const first = watchClose(port1)
  const second = watchClose(port2)
  port1.postMessage('for second')
  port2.postMessage('for first')
  port1.close()
  port2.close()
  assert.equal(take(port1), 'for first')
  assert.equal(take(port2), 'for second')
  await afterClose(first, second)
  assert.equal(receiveMessageOnPort(port1), undefined)
  assert.equal(receiveMessageOnPort(port2), undefined)
})

await check('a transferred payload received while closing remains independently usable', async ({ channel, port }) => {
  const pair = channel()
  const inner = channel()
  const local = watchClose(pair.port1)
  const peer = watchClose(pair.port2)
  const old = watchClose(inner.port1)
  const innerPeer = watchClose(inner.port2)
  const buffer = new Uint8Array([1, 2, 3, 4]).buffer
  const payload = { port: inner.port1, buffer, nested: { value: 'snapshot' } }
  pair.port1.close()
  pair.port2.postMessage(payload, [inner.port1, buffer])
  payload.nested.value = 'modified after send'
  assert.equal(buffer.byteLength, 0)
  const received = take(pair.port1)
  const moved = port(received.port)
  const movedClose = watchClose(moved)
  assert.deepEqual([...new Uint8Array(received.buffer)], [1, 2, 3, 4])
  assert.deepEqual(received.nested, { value: 'snapshot' })
  inner.port2.postMessage('the transferred endpoint still works')
  assert.equal(take(moved), 'the transferred endpoint still works')
  await afterClose(local, peer, old)
  assert.equal(movedClose.calls.length, 0)
  assert.equal(innerPeer.calls.length, 0)
  moved.postMessage('independent after carrier closure')
  assert.equal(take(inner.port2), 'independent after carrier closure')
  moved.close()
  await afterClose(movedClose, innerPeer)
})

await check('a closing sender still validates clones and disposes transferred resources', async ({ channel }) => {
  const pair = channel()
  const inner = channel()
  const local = watchClose(pair.port1)
  const peer = watchClose(pair.port2)
  const old = watchClose(inner.port1)
  const innerPeer = watchClose(inner.port2)
  pair.port1.close()
  assert.throws(() => pair.port1.postMessage(() => {}), { name: 'DataCloneError', code: 25 })
  const buffer = new ArrayBuffer(8)
  pair.port1.postMessage(buffer, [buffer])
  assert.equal(buffer.byteLength, 0)
  pair.port1.postMessage(inner.port1, [inner.port1])
  assert.equal(receiveMessageOnPort(pair.port2), undefined)
  await afterClose(local, peer, old, innerPeer)
  assert.equal(receiveMessageOnPort(inner.port2), undefined)
})

for (const state of ['fully closed', 'transferred away']) {
  await check('inactive sender still disposes transferred resources: ' + state, async ({ channel, port }) => {
    const pair = channel()
    const carrier = channel()
    const local = watchClose(pair.port1)
    const peer = watchClose(pair.port2)
    let moved
    let movedClose
    if (state === 'fully closed') {
      pair.port1.close()
      await afterClose(local, peer)
    } else {
      carrier.port1.postMessage(pair.port1, [pair.port1])
      moved = port(take(carrier.port2))
      movedClose = watchClose(moved)
      await afterClose(local)
      assert.equal(peer.calls.length, 0)
    }
    const inner = channel()
    const innerFirst = watchClose(inner.port1)
    const innerSecond = watchClose(inner.port2)
    const buffer = new ArrayBuffer(8)
    pair.port1.postMessage({ port: inner.port1, buffer }, [inner.port1, buffer])
    assert.equal(buffer.byteLength, 0)
    assert.throws(() => pair.port1.postMessage(() => {}), { name: 'DataCloneError', code: 25 })
    assert.equal(receiveMessageOnPort(pair.port2), undefined)
    await afterClose(innerFirst, innerSecond)
    assert.equal(receiveMessageOnPort(inner.port2), undefined)
    if (moved) {
      moved.postMessage('new owner is independent of discarded old-owner sends')
      assert.equal(take(pair.port2), 'new owner is independent of discarded old-owner sends')
      moved.close()
      await afterClose(movedClose, peer)
    }
  })
}

await check('a pending-closing sender can consume its still-active former peer', async ({ channel }) => {
  const { port1, port2 } = channel()
  const local = watchClose(port1)
  const peer = watchClose(port2)
  port2.postMessage('accepted before the former peer is transferred')
  port1.close()
  assert.throws(() => port1.postMessage(port1, [port1]), { name: 'DataCloneError', code: 25 })
  assert.doesNotThrow(() => port1.postMessage(port2, [port2]))
  assert.equal(take(port1), 'accepted before the former peer is transferred')
  await afterClose(local, peer)
  assert.equal(receiveMessageOnPort(port1), undefined)
})

await check('a transferred-away sender can consume either active endpoint of its former pipe', async ({ channel, port }) => {
  for (const target of ['former peer', 'new owner']) {
    const pair = channel()
    const carrier = channel()
    const old = watchClose(pair.port1)
    const peer = watchClose(pair.port2)
    carrier.port1.postMessage(pair.port1, [pair.port1])
    const moved = port(take(carrier.port2))
    const movedClose = watchClose(moved)
    await afterClose(old)
    assert.equal(peer.calls.length, 0)
    assert.equal(movedClose.calls.length, 0)
    assert.throws(() => pair.port1.postMessage(pair.port1, [pair.port1]), { name: 'DataCloneError', code: 25 })
    const endpoint = target === 'former peer' ? pair.port2 : moved
    assert.doesNotThrow(() => pair.port1.postMessage(endpoint, [endpoint]))
    await afterClose(peer, movedClose)
  }
})

assert.equal(passed, 15)
console.log('native worker pending-close regressions passed: ' + passed)
