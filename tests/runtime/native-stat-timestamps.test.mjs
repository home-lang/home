import assert from 'node:assert/strict'
import { mkdtempSync, statSync, utimesSync, writeFileSync, rmSync } from 'node:fs'
import { stat as statAsync } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const root = mkdtempSync(join(tmpdir(), 'home-stat-timestamps-'))
const file = join(root, 'file')
const fields = ['atime', 'mtime', 'ctime', 'birthtime']
writeFileSync(file, 'timestamp precision')
try {
  const initial = statSync(file)
  const bigInitial = statSync(file, { bigint: true })
  const metadata = Object.getOwnPropertySymbols(initial)
  assert.equal(metadata.length, 4)
  for (const field of fields) {
    const description = field === 'birthtime' ? 'kPartialBirthtimeNs' : `partial${field[0].toUpperCase()}${field.slice(1)}Ns`
    const symbol = metadata.find(key => key.description === description)
    assert.ok(symbol, description)
    const ns = bigInitial[`${field}Ns`]
    assert.equal(BigInt(initial[symbol]), (ns % 1000000000n + 1000000000n) % 1000000000n)
    assert.deepEqual(Object.getOwnPropertyDescriptor(initial, symbol), {
      value: initial[symbol], writable: true, enumerable: true, configurable: true,
    })
  }
  for (const stats of [initial, bigInitial]) {
    for (const field of fields) {
      const key = `${field}Instant`
      const descriptor = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(stats), key)
      assert.equal(typeof descriptor.get, 'function')
      assert.equal(typeof descriptor.set, 'function')
      assert.equal(descriptor.enumerable, true)
      assert.equal(descriptor.configurable, true)
      assert.equal(Object.hasOwn(stats, key), false)
      if (typeof Temporal === 'undefined') {
        assert.throws(() => stats[key], { name: 'Error', code: 'ERR_NO_TEMPORAL', message: 'Temporal is not supported in this environment' })
        assert.equal(Object.hasOwn(stats, key), false)
      } else {
        const instant = stats[key]
        assert.ok(instant instanceof Temporal.Instant)
        assert.equal(instant.epochNanoseconds, bigInitial[`${field}Ns`])
        assert.equal(stats[key], instant)
        assert.deepEqual(Object.getOwnPropertyDescriptor(stats, key), { value: instant, writable: true, enumerable: true, configurable: true })
        delete stats[key]
      }
      stats[key] = 'replacement'
      assert.equal(stats[key], 'replacement')
      delete stats[key]
    }
  }

  // Receiver property access happens before the Temporal availability check.
  for (const stats of [initial, bigInitial]) {
    const prototype = Object.getPrototypeOf(stats)
    const getter = Object.getOwnPropertyDescriptor(prototype, 'atimeInstant').get
    const marker = new Error('timestamp getter marker')
    const receiver = Object.create(prototype)
    Object.defineProperty(receiver, typeof stats.atimeMs === 'bigint' ? 'atimeNs' : 'atimeMs', {
      get() { throw marker },
    })
    assert.throws(() => getter.call(receiver), error => error === marker)
  }

  // Exercise both pre-epoch and > signed-64-bit nanosecond timestamps.
  // Date inputs preserve negative times (numeric negative utimes means now).
  for (const milliseconds of [-2208988800000, -1, 0, 1234567890123, 16725225600000]) {
    const date = new Date(milliseconds)
    utimesSync(file, date, date)
    const intended = BigInt(milliseconds) * 1000000n
    const observed = statSync(file, { bigint: true })
    const expected = observed.atimeNs
    // Darwin's filesystem clamps these dates to signed-64-bit nanoseconds;
    // both Node and Home report that same native limit. Constructor coverage
    // below separately proves values beyond the filesystem's range.
    const stored = process.platform === 'darwin' && intended > 9223372036854775807n
      ? 9223372036854775807n : intended
    const delta = expected - stored
    assert.ok(delta >= -1000n && delta <= 1000n, `filesystem utimes rounding: ${delta}`)
    for (const stats of [statSync(file, { bigint: true }), await statAsync(file, { bigint: true })]) {
      assert.equal(stats.atimeNs, expected)
      assert.equal(stats.mtimeNs, expected)
      assert.equal(stats.atimeMs, expected / 1000000n)
      assert.equal(stats.mtimeMs, expected / 1000000n)
      if (typeof Temporal !== 'undefined') {
        assert.equal(stats.atimeInstant.epochNanoseconds, expected)
        assert.equal(stats.mtimeInstant.epochNanoseconds, expected)
      }
    }
    if (typeof Temporal !== 'undefined') {
      for (const stats of [statSync(file), await statAsync(file)]) {
        assert.equal(stats.atimeInstant.epochNanoseconds, expected)
        assert.equal(stats.mtimeInstant.epochNanoseconds, expected)
      }
    }
  }

  if (typeof Temporal !== 'undefined') {
    utimesSync(file, 1713037251.123456, 1713037251.999999)
    const precise = statSync(file, { bigint: true })
    const preciseNormal = statSync(file)
    Bun.gc(true)
    assert.equal(preciseNormal.atimeInstant.epochNanoseconds, precise.atimeNs)
    assert.equal(preciseNormal.mtimeInstant.epochNanoseconds, precise.mtimeNs)
    delete preciseNormal.atimeInstant
    Bun.gc(true)
    assert.equal(preciseNormal.atimeInstant.epochNanoseconds, precise.atimeNs)
    const stats = statSync(file)
    const fraction = statSync(file, { bigint: true }).atimeNs % 1000000000n
    stats.atimeMs = 3000
    assert.equal(stats.atimeInstant.epochNanoseconds, 3000000000n + fraction)
    const big = statSync(file, { bigint: true })
    big.atimeNs = -123456789012345678901n
    assert.equal(big.atimeInstant.epochNanoseconds, big.atimeNs)
    for (const bigMode of [false, true]) {
      const frozen = Object.preventExtensions(statSync(file, { bigint: bigMode }))
      assert.throws(() => frozen.atimeInstant, TypeError)
      assert.throws(() => { frozen.mtimeInstant = 'value' }, TypeError)
      assert.equal(Object.hasOwn(frozen, 'atimeInstant'), false)
      assert.equal(Object.hasOwn(frozen, 'mtimeInstant'), false)
      const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(frozen), 'mtimeInstant').set
      assert.throws(() => setter.call(3, 'value'), TypeError)
      assert.throws(() => setter.call(null, 'value'), TypeError)
    }
    for (const bigMode of [false, true]) {
      const source = statSync(file, { bigint: bigMode })
      const expectedNs = statSync(file, { bigint: true }).atimeNs
      assert.equal(Object.create(source).atimeInstant.epochNanoseconds, expectedNs)
      assert.equal(new Proxy(source, {}).atimeInstant.epochNanoseconds, expectedNs)
    }
    const originalTemporal = globalThis.Temporal
    try {
      globalThis.Temporal = undefined
      // Both Stats variants share the constructor captured by the first access.
      assert.ok(statSync(file).mtimeInstant instanceof originalTemporal.Instant)
      assert.ok(statSync(file, { bigint: true }).mtimeInstant instanceof originalTemporal.Instant)
    } finally {
      globalThis.Temporal = originalTemporal
    }
    const Constructor = big.constructor
    const constructed = new Constructor(0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n,
      -123456789012345678901n, 123456789012345678901n, 0n, 1n)
    assert.equal(constructed.atimeMs, -123456789012345n)
    assert.equal(constructed.mtimeMs, 123456789012345n)
    assert.equal(constructed.atimeInstant.epochNanoseconds, -123456789012345678901n)
    assert.equal(constructed.mtimeInstant.epochNanoseconds, 123456789012345678901n)
    const called = Constructor(0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n,
      -123456789012345678901n, 123456789012345678901n, 0n, 1n)
    assert.equal(called.atimeMs, constructed.atimeMs)
    assert.equal(called.mtimeMs, constructed.mtimeMs)
    class DerivedBigIntStats extends Constructor {}
    const derived = new DerivedBigIntStats(0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n,
      -123456789012345678901n, 123456789012345678901n, 0n, 1n)
    assert.ok(derived instanceof DerivedBigIntStats)
    assert.equal(derived.atimeMs, constructed.atimeMs)
    assert.equal(derived.atimeInstant.epochNanoseconds, constructed.atimeNs)
    const SmallConstructor = initial.constructor
    for (const small of [new SmallConstructor(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, 1.125, 0, 0),
      SmallConstructor(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, 1.125, 0, 0)]) {
      assert.equal(small.atimeInstant.epochNanoseconds, -1000000n)
      assert.equal(small.mtimeInstant.epochNanoseconds, 1125000n)
    }
  }
  console.log(`native Stats timestamp precision, descriptors and lazy accessors passed; Temporal=${typeof Temporal}`)
} finally {
  rmSync(root, { recursive: true, force: true })
}
