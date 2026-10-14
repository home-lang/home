import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtempSync, writeFileSync, fstatSync, rmSync, createReadStream } from 'node:fs'
import { open } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Worker, MessageChannel } from 'node:worker_threads'

const root = mkdtempSync(join(tmpdir(), 'home-native-file-transfer-'))
const file = join(root, 'data')
writeFileSync(file, 'native transfer data')
try {
  const handle = await open(file, 'r')
  const fd = handle.fd
  const graph = { handle, array: [handle], map: new Map([[handle, handle]]), set: new Set([handle]) }
  graph.self = graph
  const worker = new Worker(`
    const { parentPort, workerData } = require('node:worker_threads');
    (async () => {
      const { handle, array, map, set } = workerData;
      const identity = workerData.self === workerData && array[0] === handle && map.get(handle) === handle && set.has(handle);
      const text = await handle.readFile('utf8');
      await handle.close();
      parentPort.postMessage({ identity, text, fd: handle.fd });
    })().catch(error => { throw error });
  `, { eval: true, workerData: graph, transferList: [handle] })
  assert.equal(handle.fd, -1)
  await assert.rejects(handle.readFile(), { code: 'EBADF' })
  const [message] = await once(worker, 'message')
  assert.deepEqual(message, { identity: true, text: 'native transfer data', fd: -1 })
  await once(worker, 'exit')
  assert.throws(() => fstatSync(fd), { code: 'EBADF' })

  console.log('transfer-stage: rollback')
  const rollback = await open(file, 'r')
  const rollbackFd = rollback.fd
  assert.throws(() => structuredClone({ handle: rollback, bad() {} }, { transfer: [rollback] }), { name: 'DataCloneError' })
  assert.equal(rollback.fd, rollbackFd)
  assert.equal(await rollback.readFile('utf8'), 'native transfer data')
  assert.throws(() => structuredClone(rollback, { transfer: [rollback, rollback] }), { name: 'DataCloneError' })
  assert.equal(rollback.fd, rollbackFd)
  await rollback.close()

  console.log('transfer-stage: virtual-stream')
  const virtual = await open(file, 'r')
  Object.defineProperty(virtual, 'fd', { value: 999999, configurable: true })
  const virtualStream = createReadStream(null, { fd: virtual })
  await assert.rejects(async () => {
    for await (const chunk of virtualStream) assert.fail('overridden fd must fail before delivering data')
  }, { code: 'EBADF' })
  console.log('transfer-stage: virtual-stream read rejected')
  await virtual.close()
  console.log('transfer-stage: virtual-stream closed')

  console.log('transfer-stage: in-use')
  const inUse = await open(file, 'r')
  const stream = createReadStream(null, { fd: inUse })
  assert.throws(() => structuredClone(inUse, { transfer: [inUse] }), { name: 'DataCloneError' })
  stream.destroy()
  await once(stream, 'close')
  await inUse.close()

  console.log('transfer-stage: override-transfer')
  const overridden = await open(file, 'r')
  Object.defineProperty(overridden, 'fd', { value: 999999, configurable: true })
  await assert.rejects(overridden.readFile('utf8'), { code: 'EBADF' })
  const realOwner = structuredClone(overridden, { transfer: [overridden] })
  assert.equal((await realOwner.stat()).size, 'native transfer data'.length)
  await realOwner.close()

  console.log('transfer-stage: direct-clone')
  const direct = await open(file, 'r')
  const cloned = structuredClone({ direct, alias: direct }, { transfer: [direct] })
  assert.equal(direct.fd, -1)
  assert.equal(cloned.direct, cloned.alias)
  assert.equal(await cloned.direct.readFile('utf8'), 'native transfer data')
  await cloned.direct.close()

  console.log('transfer-stage: dropped-message')
  const droppedChannel = new MessageChannel()
  const dropped = await open(file, 'r')
  const droppedFd = dropped.fd
  droppedChannel.port1.postMessage({ dropped }, [dropped])
  assert.equal(dropped.fd, -1)
  droppedChannel.port2.close()
  droppedChannel.port1.close()
  let closed = false
  for (let i = 0; i < 100; i++) {
    try { fstatSync(droppedFd) } catch (error) {
      assert.equal(error.code, 'EBADF')
      closed = true
      break
    }
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  assert.ok(closed, 'dropped message releases its native descriptor ticket')

  console.log('transfer-stage: channel')
  const channel = new MessageChannel()
  const sent = await open(file, 'r')
  const receive = once(channel.port2, 'message')
  channel.port1.postMessage({ sent, alias: sent }, [sent])
  assert.equal(sent.fd, -1)
  const [received] = await receive
  assert.equal(received.sent, received.alias)
  assert.equal(await received.sent.readFile('utf8'), 'native transfer data')
  await received.sent.close()
  channel.port1.close()
  channel.port2.close()

  console.log('transfer-stage: ordinary-data')
  const plain = { __bunNodeWorkerJSTransferable: 'internal/fs/promises:FileHandle', data: { fd: 999999, flag: 'r' } }
  const markerWorker = new Worker(`const { parentPort, workerData } = require('node:worker_threads'); parentPort.postMessage(workerData)`, { eval: true, workerData: plain })
  assert.deepEqual((await once(markerWorker, 'message'))[0], plain)
  await once(markerWorker, 'exit')

  console.log('transfer-stage: unused-transfer')
  const unused = await open(file, 'r')
  const unusedFd = unused.fd
  const unusedWorker = new Worker(`const { parentPort } = require('node:worker_threads'); parentPort.postMessage('ready')`, { eval: true, workerData: {}, transferList: [unused] })
  assert.equal(unused.fd, -1)
  await once(unusedWorker, 'message')
  await once(unusedWorker, 'exit')
  assert.throws(() => fstatSync(unusedFd), { code: 'EBADF' })
  console.log('transfer-stage: termination')
  const abandoned = await open(file, 'r')
  const abandonedFd = abandoned.fd
  const abandonedWorker = new Worker('setInterval(() => {}, 1000)', {
    eval: true, workerData: { abandoned }, transferList: [abandoned],
  })
  assert.equal(abandoned.fd, -1)
  await abandonedWorker.terminate()
  assert.throws(() => fstatSync(abandonedFd), { code: 'EBADF' })

  console.log('native FileHandle transfer identity, receiver I/O, rollback, in-use rejection, channel transport, plain data and unused descriptor cleanup passed')
} finally {
  rmSync(root, { recursive: true, force: true })
}
