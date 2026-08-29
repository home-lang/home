import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { heapStats } from 'bun:jsc'
import { jest } from 'bun:test'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

try {
  // Getter validation must finish before changing the currently active clock.
  let reads = 0
  const inherited = Object.create({ get now() { reads++; return 1000 } })
  assert.equal(jest.useFakeTimers(inherited), jest)
  assert.equal(reads, 1)
  assert.equal(Date.now(), 1000)
  assert.equal(new Date().getTime(), 1000)
  assert.equal(performance.now(), 0)
  assert.equal(Object.hasOwn(setTimeout, 'clock'), true)
  const getterError = new Error('clock getter failed')
  assert.throws(() => jest.useFakeTimers({ get now() { throw getterError } }), error => error === getterError)
  for (const value of [null, false, 1, 'bad']) assert.throws(() => jest.useFakeTimers(value))
  for (const now of [null, false, 'bad', {}]) assert.throws(() => jest.useFakeTimers({ now }))
  assert.equal(Date.now(), 1000)
  assert.equal(jest.isFakeTimers(), true)

  // Deadlines, nested callbacks, intervals, Date and performance share a clock.
  const seen = []
  const interval = setInterval(() => seen.push(['interval', Date.now(), performance.now()]), 2)
  setTimeout(() => {
    seen.push(['outer', Date.now(), performance.now()])
    setTimeout(() => seen.push(['inner', Date.now(), performance.now()]), 1)
  }, 3)
  jest.advanceTimersByTime(4.5)
  assert.deepEqual(seen, [
    ['interval', 1002, 2], ['outer', 1003, 3],
    ['interval', 1004, 4], ['inner', 1004, 4],
  ])
  assert.equal(Date.now(), 1004)
  assert.equal(performance.now(), 4.5)
  clearInterval(interval)
  jest.advanceTimersByTime(0.5)
  assert.equal(Date.now(), 1005)
  assert.equal(performance.now(), 5)
  assert.equal(jest.getTimerCount(), 0)

  // Clearing a heap must preserve live JS handles without letting them revive
  // cancelled callbacks, and must allow the process to exit naturally.
  const retained = setTimeout(() => assert.fail('cleared timer fired'), 100)
  void +retained
  jest.clearAllTimers()
  assert.equal(retained.hasRef(), false)
  assert.equal(retained._destroyed, true)
  assert.equal(retained.refresh(), retained)
  assert.equal(jest.getTimerCount(), 0)
  jest.useRealTimers()
  assert.equal(Object.hasOwn(setTimeout, 'clock'), false)

  // Both reset paths must release timer and AbortSignal wrapper references.
  // Repeated allocations expose a leak even if a single count looks plausible.
  Bun.gc(true); Bun.gc(true)
  const before = heapStats().objectTypeCounts
  for (const reset of [() => jest.clearAllTimers(), () => jest.useRealTimers()]) {
    for (let round = 0; round < 24; round++) {
      jest.useFakeTimers({ now: new Date(2000) })
      assert.equal(Date.now(), 2000)
      for (let i = 0; i < 32; i++) {
        void +setTimeout(() => assert.fail('stale timeout'), 3_600_000)
        setInterval(() => assert.fail('stale interval'), 3_600_000)
        AbortSignal.timeout(3_600_000).addEventListener('abort', () => assert.fail('stale abort'))
      }
      reset()
      jest.useRealTimers()
      Bun.gc(true); Bun.gc(true)
    }
    const after = heapStats().objectTypeCounts
    for (const type of ['Timeout', 'AbortSignal']) {
      assert.ok((after[type] ?? 0) <= (before[type] ?? 0) + 4, `${type} retained after reset: ${after[type]} vs ${before[type]}`)
    }
  }
  await Bun.sleep(2)
  assert.equal(jest.isFakeTimers(), false)
  console.log('native fake-clock and reset-lifetime regressions passed')
} finally {
  jest.useRealTimers()
}
