import assert from 'node:assert/strict'
import { AsyncLocalStorage } from 'node:async_hooks'
import { basename } from 'node:path'
import { setImmediate as immediate } from 'node:timers/promises'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

for (const flush of [false, true]) {
  const storage = new AsyncLocalStorage()
  const reason = { flush }
  let calls = 0
  let source
  let pulled = false
  const stream = storage.run('creation', () => new ReadableStream(source = {
    type: 'direct',
    pull(controller) { if (!pulled) { pulled = true; controller.write('hello'); if (flush) controller.flush() } },
    cancel(actualReason) {
      assert.equal(this, source)
      assert.equal(actualReason, reason)
      assert.equal(storage.getStore(), 'creation')
      Bun.gc(true)
      calls++
      return Promise.resolve('ignored result')
    },
  }))
  const reader = stream.getReader()
  const first = reader.read()
  if (flush) assert.equal((await first).value.byteLength, 5)
  const pending = flush ? reader.read() : first
  await storage.run('caller', async () => {
    assert.equal(await reader.cancel(reason), undefined)
    assert.equal(storage.getStore(), 'caller')
  })
  assert.deepEqual(await pending, { value: undefined, done: true })
  assert.deepEqual(await reader.read(), { value: undefined, done: true })
  await reader.cancel('again')
  assert.equal(calls, 1)
  assert.equal(storage.getStore(), undefined)
  reader.releaseLock()
}

for (const callback of ['cancel', 'close']) {
  let calls = 0
  const stream = new ReadableStream({ type: 'direct', pull() { assert.fail('lazy cancellation must not pull') }, [callback](reason) { assert.equal(reason, 'lazy'); calls++ } })
  await stream.cancel('lazy')
  await stream.cancel('again')
  assert.equal(calls, 1)
}

for (const asynchronous of [false, true]) {
  const error = new Error('cancel failure')
  const stream = new ReadableStream({ type: 'direct', pull() {}, cancel() { if (asynchronous) return Promise.reject(error); throw error } })
  const reader = stream.getReader()
  const pending = reader.read()
  await assert.rejects(reader.cancel(), actual => actual === error)
  assert.deepEqual(await pending, { value: undefined, done: true })
  await reader.cancel()
  reader.releaseLock()
}

const latePull = Promise.withResolvers()
const lateStream = new ReadableStream({ type: 'direct', pull() { return latePull.promise } })
const lateReader = lateStream.getReader()
const lateRead = lateReader.read()
await lateReader.cancel()
assert.deepEqual(await lateRead, { value: undefined, done: true })
latePull.reject(new Error('rejected after cancellation'))
await immediate()
lateReader.releaseLock()

const cancelCompletion = Promise.withResolvers()
let concurrentCalls = 0
const concurrentStream = new ReadableStream({ type: 'direct', cancel() { concurrentCalls++; return cancelCompletion.promise } })
const firstCancel = concurrentStream.cancel()
await concurrentStream.cancel()
assert.equal(concurrentCalls, 1)
cancelCompletion.resolve('ignored')
assert.equal(await firstCancel, undefined)

const closedStream = new ReadableStream({ type: 'direct', pull(controller) { controller.close() }, cancel() { assert.fail('closed stream must not invoke cancellation') } })
const closedReader = closedStream.getReader()
assert.deepEqual(await closedReader.read(), { value: undefined, done: true })
await closedReader.cancel()
closedReader.releaseLock()
const storedError = new Error('stored direct error')
const erroredStream = new ReadableStream({ type: 'direct', pull(controller) { controller.error(storedError) }, cancel() { assert.fail('errored stream must not invoke cancellation') } })
const erroredReader = erroredStream.getReader()
await assert.rejects(erroredReader.read(), actual => actual === storedError)
await assert.rejects(erroredReader.cancel(), actual => actual === storedError)
erroredReader.releaseLock()

let reader
const reentrant = new ReadableStream({ type: 'direct', pull() { reader.cancel('inside pull') } })
reader = reentrant.getReader()
assert.deepEqual(await reader.read(), { value: undefined, done: true })
reader.releaseLock()

const released = new ReadableStream({ type: 'direct', pull() {} })
const releasedReader = released.getReader()
const releasedRead = releasedReader.read()
releasedReader.releaseLock()
await assert.rejects(releasedRead, { code: 'ERR_STREAM_RELEASE_LOCK' })
await released.cancel()

for (const mode of ['default', 'byob']) {
  let calls = 0
  const stream = new ReadableStream({ type: mode === 'byob' ? 'bytes' : undefined, cancel(reason) { calls++; assert.equal(reason, 'bytes') } })
  const reader = stream.getReader(mode === 'byob' ? { mode } : undefined)
  const pending = mode === 'byob' ? reader.read(new Uint8Array(16)) : reader.read()
  await reader.cancel('bytes')
  assert.deepEqual(await pending, { value: undefined, done: true })
  await reader.closed
  assert.equal(calls, 1)
  reader.releaseLock()
}
console.log('native direct/default/BYOB cancellation regressions passed')

// FileHandle byte streams retain native I/O ownership and honor autoClose.
{
 const fs = await import("node:fs")
 const { tmpdir } = await import("node:os")
 const { join } = await import("node:path")
const dir=fs.mkdtempSync(join(tmpdir(),'home-filehandle-webstream-'))
const file=join(dir,'data.txt'), payload=Buffer.from('ordinary byte stream data')
fs.writeFileSync(file,payload)
try {
 for(const mode of ['default','byob']){
  const handle=await fs.promises.open(file,'r')
  const stream=handle.readableWebStream({autoClose:true})
  const reader=mode==='byob'?stream.getReader({mode:'byob'}):stream.getReader()
  const chunks=[]
  for(;;){const result=mode==='byob'?await reader.read(new Uint8Array(7)):await reader.read();if(result.done)break;assert(result.value instanceof Uint8Array);chunks.push(Buffer.from(result.value))}
  assert.deepEqual(Buffer.concat(chunks),payload)
  assert.equal(handle.fd,-1)
  await reader.closed;reader.releaseLock();await handle.close()
 }
 const empty=join(dir,'empty.txt');fs.writeFileSync(empty,'')
 const emptyHandle=await fs.promises.open(empty,'r')
 const emptyReader=emptyHandle.readableWebStream({autoClose:true}).getReader({mode:'byob'})
 const eof=await emptyReader.read(new Uint8Array(4));assert.equal(eof.done,true);assert.equal(eof.value.byteLength,0);emptyReader.releaseLock();assert.equal(emptyHandle.fd,-1)
 const retained=await fs.promises.open(file,'r')
 const reader=retained.readableWebStream().getReader()
 await reader.cancel('finished');reader.releaseLock()
 assert.ok(retained.fd>=0);await retained.close()
 const cancelled=await fs.promises.open(file,'r')
 const cancelReader=cancelled.readableWebStream({autoClose:true}).getReader()
 await cancelReader.cancel('ordinary cancellation');cancelReader.releaseLock()
 assert.equal(cancelled.fd,-1)
 const once=await fs.promises.open(file,'r')
 const first=once.readableWebStream();assert.throws(()=>once.readableWebStream(),{code:'ERR_INVALID_STATE'})
 await first.cancel();await once.close()
 const warnings=[]
 const onWarning=warning=>{if(warning.name==='ExperimentalWarning')warnings.push(warning.message)}
 process.on('warning',onWarning)
 const legacy=await fs.promises.open(file,'r')
 const legacyReader=legacy.readableWebStream({type:'default',autoClose:true}).getReader({mode:'byob'})
 assert((await legacyReader.read(new Uint8Array(5))).value instanceof Uint8Array)
 await legacyReader.cancel();legacyReader.releaseLock();await new Promise(resolve=>setImmediate(resolve));process.removeListener('warning',onWarning)
 assert.equal(warnings.length,1);assert.equal(legacy.fd,-1)
 const invalid=await fs.promises.open(file,'r')
 assert.throws(()=>invalid.readableWebStream({autoClose:'yes'}),{code:'ERR_INVALID_ARG_TYPE'})
 await invalid.close()
 console.log('FileHandle byte/BYOB streams, autoClose on EOF and cancellation, retained ownership and option/lock validation passed')
} finally {fs.rmSync(dir,{recursive:true,force:true})}
}

// FileHandle writeFile forwards durability options to the native write lane.
{
 const fs = await import("node:fs")
 const { tmpdir } = await import("node:os")
 const { join } = await import("node:path")
const dir=fs.mkdtempSync(join(tmpdir(),'home-filehandle-options-'))
try {
 const path=join(dir,'data.txt'), handle=await fs.promises.open(path,'w+')
 try {
  await assert.rejects(handle.writeFile('invalid flush',{flush:'yes'}),{code:'ERR_INVALID_ARG_TYPE'})
  await handle.writeFile('ordinary data',{flush:true})
  assert.equal(fs.readFileSync(path,'utf8'),'ordinary data')
  await fs.promises.writeFile(handle,' second',{flush:true})
  assert.equal((await fs.promises.readFile(handle)).length,0)
 } finally {await handle.close()}
 const readHandle=await fs.promises.open(path,'r')
 try {
  await readHandle.read(Buffer.alloc(3),0,3,null)
  assert.equal((await fs.promises.readFile(readHandle)).toString(),'inary data second')
 } finally {await readHandle.close()}
 console.log('FileHandle flush options and public read/writeFile preserve native handle operations and offsets')
} finally {fs.rmSync(dir,{recursive:true,force:true})}
}

// FileHandle.close remains bound when passed directly as cleanup.
{
  const fs = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const { join } = await import('node:path')
  const directory = fs.mkdtempSync(join(tmpdir(), 'home-filehandle-bound-close-'))
  try {
    const path = join(directory, 'lines.txt')
    fs.writeFileSync(path, 'abc\ndef\n')
    const handle = await fs.promises.open(path, 'r')
    assert.ok(Object.hasOwn(handle, 'close'))
    const close = handle.close
    await close()
    assert.equal(handle.fd, -1)
    await close()
    await assert.rejects(handle.read(Buffer.alloc(1)), { code: 'EBADF', syscall: 'read' })
    const retained = await fs.promises.open(path, 'r')
    try {
      const lines = []
      for await (const line of retained.readLines({ autoClose: false })) lines.push(line)
      assert.deepEqual(lines, ['abc', 'def'])
      assert.ok(retained.fd >= 0)
    }
    finally { await retained.close() }
  }
  finally { fs.rmSync(directory, { recursive: true, force: true }) }
}

// Native FileHandle ownership and close requests expose their real resource IDs.
{
  const { createHook, AsyncResource } = await import('node:async_hooks')
  const fs = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const { join } = await import('node:path')
  const directory = fs.mkdtempSync(join(tmpdir(), 'home-filehandle-native-'))
  const path = join(directory, 'file')
  fs.writeFileSync(path, 'abc')
  const handles = new Map()
  const closes = new Map()
  const before = new Set()
  const after = new Set()
  const destroyed = new Set()
  const hook = createHook({
    init(id, type, trigger, resource) {
      if (type === 'FILEHANDLE') handles.set(id, { trigger, resource })
      if (type === 'FILEHANDLECLOSEREQ') closes.set(id, resource)
    },
    before(id) { if (closes.has(id)) before.add(id) },
    after(id) { if (closes.has(id)) after.add(id) },
    destroy(id) { if (closes.has(id)) destroyed.add(id) },
  }).enable()
  try {
    const outer = new AsyncResource('open-owner')
    const handle = await outer.runInAsyncScope(() => fs.promises.open(path, 'r'))
    const id = handle.getAsyncId()
    assert.ok(Number.isSafeInteger(id) && id > 0)
    assert.equal(handles.get(id).trigger, 0)
    assert.notEqual(handles.get(id).resource, handle)
    assert.equal(handles.get(id).resource.fd, handle.fd)
    await handle.read(Buffer.alloc(1))
    assert.equal(handle.getAsyncId(), id)
    await handle.close()
    assert.equal(handle.getAsyncId(), id)
    assert.ok(handles.get(id).resource.fd < 0)
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(closes.size, 1)
    const closeId = [...closes.keys()][0]
    assert(before.has(closeId))
    assert(after.has(closeId))
    assert(destroyed.has(closeId))
    const second = await fs.promises.open(path, 'r')
    assert.notEqual(second.getAsyncId(), id)
    await second.close()
    outer.emitDestroy()
  }
  finally {
    hook.disable()
    fs.rmSync(directory, { recursive: true, force: true })
  }
}

// Promise watchers are lazy native async iterators with one cleanup scope.
async function verifyPromiseWatchIterator() {
  const fs = await import('node:fs')
  const { pathToFileURL } = await import('node:url')
  const { join } = await import('node:path')
  const { tmpdir } = await import('node:os')
  const directory = fs.mkdtempSync(join(tmpdir(), 'home-watch-iterator-'))
  try {
    const reason = new Error('ordinary abort')
    const pre = fs.promises.watch(pathToFileURL(directory), { signal: AbortSignal.abort(reason) })
    assert.equal(typeof pre.next, 'function')
    assert.strictEqual(pre[Symbol.asyncIterator](), pre)
    await assert.rejects(pre.next(), error => error.name === 'AbortError' && error.cause === reason)
    assert.deepEqual(await pre.next(), { value: undefined, done: true })
    const unopened = fs.promises.watch(pathToFileURL(directory))
    assert.deepEqual(await unopened.return(), { value: undefined, done: true })
    const controller = new AbortController()
    const watcher = fs.promises.watch(pathToFileURL(directory), { signal: controller.signal })
    assert.strictEqual(watcher[Symbol.asyncIterator](), watcher)
    const next = watcher.next()
    controller.abort(reason)
    await assert.rejects(next, error => error.name === 'AbortError' && error.cause === reason)
    assert.deepEqual(await watcher.next(), { value: undefined, done: true })
    const events = fs.promises.watch(pathToFileURL(directory), { encoding: 'utf8', maxQueue: 16 })
    const pending = events.next()
    let timer
    try {
      await new Promise(resolve => setTimeout(resolve, 150))
      fs.writeFileSync(join(directory, 'ordinary.txt'), 'data')
      const event = await Promise.race([
        pending,
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('ordinary watch timeout')), 5000)
        }),
      ])
      assert.equal(event.done, false)
      assert.equal(typeof event.value.filename, 'string')
      assert.equal(event.value.filename, 'ordinary.txt')
    }
    finally {
      clearTimeout(timer)
      await events.return()
    }
  }
  finally { fs.rmSync(directory, { recursive: true, force: true }) }
}
verifyPromiseWatchIterator().catch(error => { throw error })

// Internal cancellation must survive stopped user abort propagation.
async function verifyProtectedCancellation() {
  const fs = await import('node:fs')
  const { getEventListeners } = await import('node:events')
  const { setTimeout: delay, setImmediate: immediate, setInterval: interval } = await import('node:timers/promises')
  const { tmpdir } = await import('node:os')
  const { join } = await import('node:path')
  assert.equal(delay.length, 2)
  assert.equal(interval.length, 2)
  assert.equal(immediate.length, 1)
  const directory = fs.mkdtempSync(join(tmpdir(), 'home-protected-abort-'))
  try {
    const reason = new Error('ordinary cancellation')
    for (const make of [
      signal => delay(30, 'timeout', { signal }),
      signal => immediate('immediate', { signal }),
      signal => interval(30, 'interval', { signal }).next(),
    ]) {
      const controller = new AbortController()
      controller.signal.addEventListener('abort', event => event.stopImmediatePropagation())
      const count = getEventListeners(controller.signal, 'abort').length
      const pending = make(controller.signal)
      controller.abort(reason)
      await assert.rejects(pending, error => error.name === 'AbortError' && error.cause === reason)
      assert.equal(getEventListeners(controller.signal, 'abort').length, count)
    }
    const controller = new AbortController()
    controller.signal.addEventListener('abort', event => event.stopImmediatePropagation())
    const count = getEventListeners(controller.signal, 'abort').length
    const watcher = fs.promises.watch(directory, { signal: controller.signal, persistent: false })
    const pending = watcher.next()
    controller.abort(reason)
    let timer
    try {
      await assert.rejects(Promise.race([
        pending,
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('watch abort did not settle')), 300)
        }),
      ]), error => error.name === 'AbortError' && error.cause === reason)
    }
    finally { clearTimeout(timer) }
    assert.equal(getEventListeners(controller.signal, 'abort').length, count)
    const sequence = interval(5, 'tick')
    assert.strictEqual(sequence[Symbol.asyncIterator](), sequence)
    const first = sequence.next()
    const second = sequence.next()
    assert.deepEqual(await first, { value: 'tick', done: false })
    assert.deepEqual(await second, { value: 'tick', done: false })
    assert.deepEqual(await sequence.return(), { value: undefined, done: true })
    assert.deepEqual(await sequence.next(), { value: undefined, done: true })
  }
  finally { fs.rmSync(directory, { recursive: true, force: true }) }
}
verifyProtectedCancellation().catch(error => { throw error })
