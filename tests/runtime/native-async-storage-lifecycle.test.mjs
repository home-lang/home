import assert from 'node:assert/strict'
import { AsyncLocalStorage, AsyncResource } from 'node:async_hooks'

const first = new AsyncLocalStorage()
const second = new AsyncLocalStorage()
first.disable()
assert.equal(first.run('reactivated', () => first.getStore()), 'reactivated')
assert.equal(first.getStore(), undefined)
first.run('outer', () => {
  first.disable()
  assert.equal(first.getStore(), undefined)
})
assert.equal(first.getStore(), undefined)
first.run('outer', () => {
  first.enterWith('replacement')
  assert.equal(first.getStore(), 'replacement')
})
assert.equal(first.getStore(), undefined)

first.run('outer', () => second.run('other', () => {
  const marker = new Error('callback error')
  assert.throws(() => first.run('inner', () => { throw marker }), error => error === marker)
  assert.equal(first.getStore(), 'outer')
  first.exit(() => {
    assert.equal(first.getStore(), undefined)
    assert.equal(second.getStore(), 'other')
    first.run('temporary', () => assert.equal(first.getStore(), 'temporary'))
  })
  assert.equal(first.getStore(), 'outer')
  assert.equal(second.getStore(), 'other')
}))
assert.equal(first.getStore(), undefined)
assert.equal(second.getStore(), undefined)

first.disable()
first.exit(() => assert.equal(first.getStore(), undefined))
assert.equal(first.getStore(), undefined)
assert.throws(() => first.run('value', null), TypeError)
assert.throws(() => first.exit(null), TypeError)
assert.equal(first.getStore(), undefined)

let snapshot
let resource
const continuation = first.run('captured', async () => {
  snapshot = AsyncLocalStorage.snapshot()
  resource = new AsyncResource('home-lifecycle')
  await Promise.resolve()
  assert.equal(first.getStore(), 'captured')
})
assert.equal(first.getStore(), undefined)
await continuation
assert.equal(snapshot(() => first.getStore()), 'captured')
assert.equal(resource.runInAsyncScope(() => first.getStore()), 'captured')
first.disable()
assert.equal(snapshot(() => first.getStore()), undefined)
assert.equal(resource.runInAsyncScope(() => first.getStore()), undefined)
resource.emitDestroy()
console.log('native async storage restoration, disable, exit, snapshots and resources passed')
