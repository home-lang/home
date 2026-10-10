import assert from 'node:assert/strict'
import { AsyncLocalStorage } from 'node:async_hooks'

const first = new AsyncLocalStorage()
const second = new AsyncLocalStorage()
const pending = []
first.run('outer', () => second.run('other', () => {
  first.exit(() => {
    assert.equal(first.getStore(), undefined)
    assert.equal(second.getStore(), 'other')
    pending.push(Promise.resolve().then(() => {
      assert.equal(first.getStore(), undefined)
      assert.equal(second.getStore(), 'other')
    }))
    pending.push(new Promise(resolve => process.nextTick(() => {
      assert.equal(first.getStore(), undefined)
      assert.equal(second.getStore(), 'other')
      resolve()
    })))
    pending.push(new Promise(resolve => setTimeout(() => {
      assert.equal(first.getStore(), undefined)
      assert.equal(second.getStore(), 'other')
      resolve()
    }, 0)))
  })
  assert.equal(first.getStore(), 'outer')
  assert.equal(second.getStore(), 'other')
}))
assert.equal(first.getStore(), undefined)
assert.equal(second.getStore(), undefined)
await Promise.all(pending)
assert.equal(first.getStore(), undefined)
assert.equal(second.getStore(), undefined)
console.log('native exit continuations omit the exited store and preserve other stores')
