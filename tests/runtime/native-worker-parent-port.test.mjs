// Native parentPort lifecycle regression: https://github.com/home-lang/home/issues/477.
// Node controls run this exact body with only the executable guard removed.
import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { Worker } from 'node:worker_threads'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

async function bounded(promise, label) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(new Error(label + ': timed out')), 3000)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

const state = new Int32Array(new SharedArrayBuffer(4))
const worker = new Worker(`
  const { parentPort, workerData } = require('node:worker_threads');
  const state = new Int32Array(workerData);
  parentPort.on('message', () => { throw new Error('closed parentPort delivered a message'); });
  parentPort.on('close', () => Atomics.add(state, 0, 1));
  parentPort.postMessage('closing');
  parentPort.close();
`, { eval: true, workerData: state.buffer })
const messages = []
const errors = []
const exits = []
worker.on('message', message => messages.push(message))
worker.on('error', error => errors.push(error))
const exit = new Promise(resolve => {
  worker.on('exit', code => {
    exits.push(code)
    resolve(code)
  })
})

try {
  assert.equal(await bounded(exit, 'parentPort.close must permit natural worker exit'), 0)
  assert.deepEqual(messages, ['closing'])
  assert.deepEqual(errors, [])
  assert.deepEqual(exits, [0])
  assert.equal(Atomics.load(state, 0), 1, 'parentPort must dispatch close exactly once')
  console.log('parentPort close releases listeners and permits natural exit')
} finally {
  if (exits.length === 0) await bounded(worker.terminate(), 'worker cleanup')
}

let passed = 1
async function scenario(name, source, workerData, onMessage) {
  const messages = []
  const errors = []
  const worker = new Worker(`
    const assert = require('node:assert/strict');
    const { parentPort, workerData, MessageChannel, receiveMessageOnPort, Worker } = require('node:worker_threads');
    ${source}
  `, { eval: true, workerData })
  let exited = false
  worker.on('message', message => {
    messages.push(message)
    onMessage?.(message, worker)
  })
  worker.on('error', error => errors.push(error))
  const exit = new Promise(resolve => worker.once('exit', code => {
    exited = true
    resolve(code)
  }))
  try {
    const code = await bounded(exit, name)
    assert.deepEqual(errors, [], name + ': unexpected worker errors')
    assert.equal(code, 0, name)
    passed++
    console.log('pass: ' + name)
    return messages
  } finally {
    if (!exited) await bounded(worker.terminate(), name + ' cleanup')
  }
}

assert.deepEqual(await scenario('parentPort ref and unref are real and idempotent', `
  assert.equal(parentPort.hasRef(), false);
  parentPort.ref(); parentPort.ref();
  assert.equal(parentPort.hasRef(), true);
  parentPort.unref(); parentPort.unref();
  assert.equal(parentPort.hasRef(), false);
  parentPort.postMessage('unrefed');
`), ['unrefed'])

assert.deepEqual(await scenario('unref overrides a live parentPort message listener', `
  parentPort.on('message', () => { throw new Error('unexpected message'); });
  assert.equal(parentPort.hasRef(), true);
  parentPort.unref();
  assert.equal(parentPort.hasRef(), false);
  parentPort.postMessage('unrefed listener');
`), ['unrefed listener'])

assert.deepEqual(await scenario('removing the final message listener releases its ref', `
  const listener = () => {};
  parentPort.on('message', listener);
  assert.equal(parentPort.hasRef(), true);
  parentPort.off('message', listener);
  assert.equal(parentPort.hasRef(), false);
  parentPort.postMessage('removed');
`), ['removed'])

assert.deepEqual(await scenario('onmessage clearing and messageerror do not retain a worker', `
  parentPort.onmessage = () => { throw new Error('cleared listener ran'); };
  assert.equal(parentPort.hasRef(), true);
  parentPort.onmessage = 'not a function';
  assert.equal(parentPort.hasRef(), false);
  parentPort.onmessageerror = () => {};
  assert.equal(parentPort.hasRef(), false);
  parentPort.postMessage('cleared');
`), ['cleared'])

const closeState = new Int32Array(new SharedArrayBuffer(16))
assert.deepEqual(await scenario('close is asynchronous, once-only, and does not exit the worker', `
  const state = new Int32Array(workerData);
  let synchronous = true;
  parentPort.on('message', () => Atomics.add(state, 2, 1));
  parentPort.on('close', function (...args) {
    assert.equal(this, parentPort);
    assert.equal(args.length, 1);
    assert.equal(args[0].type, 'close');
    assert.equal(synchronous, false);
    Atomics.add(state, 0, 1);
    parentPort.ref();
    assert.equal(parentPort.hasRef(), false);
  });
  parentPort.postMessage('before close');
  parentPort.close();
  parentPort.close();
  parentPort.postMessage('after close must not arrive');
  synchronous = false;
  setTimeout(() => { Atomics.add(state, 1, 1); }, 20);
`, closeState.buffer), ['before close'])
assert.deepEqual([...closeState], [1, 1, 0, 0])

const gate = new Int32Array(new SharedArrayBuffer(4))
assert.deepEqual(await scenario('synchronous receive consumes the real FIFO before async delivery', `
  const gate = new Int32Array(workerData);
  parentPort.on('message', () => { throw new Error('synchronously consumed message was delivered again'); });
  parentPort.postMessage('ready');
  Atomics.wait(gate, 0, 0, 2000);
  assert.equal(Atomics.load(gate, 0), 1, 'the parent queued every message before releasing the gate');
  const values = [undefined, null, false, 0, '', 17n];
  for (const message of values) assert.deepEqual(receiveMessageOnPort(parentPort), { message });
  assert.equal(receiveMessageOnPort(parentPort), undefined);
  parentPort.postMessage('received');
  parentPort.close();
`, gate.buffer, (message, target) => {
  if (message !== 'ready') return
  for (const value of [undefined, null, false, 0, '', 17n]) target.postMessage(value)
  Atomics.store(gate, 0, 1)
  Atomics.notify(gate, 0)
}), ['ready', 'received'])

const closingGate = new Int32Array(new SharedArrayBuffer(8))
assert.deepEqual(await scenario('pending parentPort close preserves synchronous queued receive', `
  const gate = new Int32Array(workerData);
  parentPort.postMessage('ready');
  Atomics.wait(gate, 0, 0, 2000);
  assert.equal(Atomics.load(gate, 0), 1);
  parentPort.close();
  assert.deepEqual(receiveMessageOnPort(parentPort), { message: false });
  assert.deepEqual(receiveMessageOnPort(parentPort), { message: 0 });
  assert.equal(receiveMessageOnPort(parentPort), undefined);
  const buffer = new ArrayBuffer(8);
  parentPort.postMessage(buffer, [buffer]);
  assert.equal(buffer.byteLength, 0, 'inactive sends still consume transfer resources');
  Atomics.store(gate, 1, 1);
`, closingGate.buffer, (message, target) => {
  if (message !== 'ready') return
  target.postMessage(false)
  target.postMessage(0)
  Atomics.store(closingGate, 0, 1)
  Atomics.notify(closingGate, 0)
}), ['ready'])
assert.equal(Atomics.load(closingGate, 1), 1)

assert.deepEqual(await scenario('parentPort can transfer to a descendant without changing its peer', `
  const child = new Worker(\`
    const assert = require('node:assert/strict');
    const { workerData } = require('node:worker_threads');
    const port = workerData;
    port.once('message', message => {
      assert.deepEqual(message, { answer: 42 });
      port.postMessage('transferred reply');
      port.close();
    });
    port.postMessage('transferred ready');
  \`, { eval: true, workerData: parentPort, transferList: [parentPort] });
  child.on('error', error => { throw error; });
  child.on('exit', code => assert.equal(code, 0));
`, undefined, (message, target) => {
  if (message === 'transferred ready') target.postMessage({ answer: 42 })
}), ['transferred ready', 'transferred reply'])

assert.deepEqual(await scenario('parentPort rejects transferring itself through its own channel', `
  assert.throws(() => parentPort.postMessage(parentPort, [parentPort]), { name: 'DataCloneError' });
  parentPort.postMessage('still usable');
  parentPort.close();
`), ['still usable'])

if (typeof Bun !== 'undefined') {
  assert.deepEqual(await scenario('native parentPort preserves the Web Worker global message surface', `
    let received;
    parentPort.once('message', message => { received = message; });
    self.onmessage = event => {
      assert.equal(event.data, received, 'the two surfaces share the same deserialized value');
      self.onmessage = null;
      parentPort.close();
      self.postMessage('shared native data');
    };
    parentPort.postMessage('ready');
  `, undefined, (message, target) => {
    if (message === 'ready') target.postMessage({ data: [1, 2, 3] })
  }), ['ready', 'shared native data'])
}

console.log('parentPort lifecycle scenarios passed: ' + passed)
