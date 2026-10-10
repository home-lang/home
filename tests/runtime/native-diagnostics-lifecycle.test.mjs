import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { AsyncLocalStorage } from 'node:async_hooks'
import { Channel, channel, subscribe, unsubscribe, hasSubscribers, tracingChannel } from 'node:diagnostics_channel'
assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const activeName = Symbol('active diagnostic retention')
let messages = 0
const listener = value => { assert.equal(value, 'alive'); messages++ }
subscribe(activeName, listener)
const weakActive = new WeakRef(channel(activeName))
await Bun.sleep(1)
for (let i = 0; i < 5; i++) { Bun.gc(true); await Bun.sleep(1) }
assert.ok(weakActive.deref(), 'active subscriptions must retain their channel')
assert.equal(hasSubscribers(activeName), true)
channel(activeName).publish('alive')
assert.equal(messages, 1)
assert.equal(unsubscribe(activeName, listener), true)
assert.equal(hasSubscribers(activeName), false)

const replacementName = Symbol('replacement diagnostic generation')
let predecessor = new Channel(replacementName)
const weakPredecessor = new WeakRef(predecessor)
const replacement = new Channel(replacementName)
predecessor = null
await Bun.sleep(1)
for (let i = 0; i < 5; i++) { Bun.gc(true); await Bun.sleep(1) }
assert.equal(weakPredecessor.deref(), undefined)
assert.equal(channel(replacementName), replacement, 'an old finalizer must not delete a replacement channel')

const scoped = channel(Symbol('diagnostic stores'))
const first = new AsyncLocalStorage()
const second = new AsyncLocalStorage()
const context = { id: 7 }
scoped.bindStore(first)
scoped.bindStore(second, data => ({ data }))
let published = 0
const scopedListener = data => { assert.equal(data, context); assert.equal(first.getStore(), context); assert.deepEqual(second.getStore(), { data: context }); published++ }
scoped.subscribe(scopedListener)
const owner = { value: 9 }
assert.equal(scoped.runStores(context, function (value) { assert.equal(this, owner); assert.equal(value, 3); assert.equal(first.getStore(), context); return 12 }, owner, 3), 12)
assert.equal(published, 1)
assert.equal(first.getStore(), undefined)
assert.equal(second.getStore(), undefined)
assert.equal(scoped.unbindStore(first), true)
assert.equal(scoped.unbindStore(second), true)
scoped.unsubscribe(scopedListener)

const errors = []
const catchError = error => errors.push(error)
process.on('uncaughtException', catchError)
const fail = channel(Symbol('diagnostic error ordering'))
const subscriberError = new Error('subscriber')
const transformError = new Error('transform')
let followingSubscriber = false
fail.subscribe(() => { throw subscriberError })
fail.subscribe(() => { followingSubscriber = true })
fail.publish(context)
assert.equal(followingSubscriber, true)
assert.equal(errors.length, 0)
const brokenStore = new AsyncLocalStorage()
fail.bindStore(brokenStore, () => { throw transformError })
let ran = false
fail.runStores(context, () => { ran = true })
assert.equal(ran, true)
await Bun.sleep(5)
assert.ok(errors.includes(subscriberError))
assert.ok(errors.includes(transformError))
process.off('uncaughtException', catchError)

const traced = tracingChannel('native diagnostic trace')
const events = []
const handlers = Object.fromEntries(['start', 'end', 'asyncStart', 'asyncEnd', 'error'].map(name => [name, value => events.push([name, value])]))
traced.subscribe(handlers)
const promiseContext = {}
assert.equal(await traced.tracePromise(() => Promise.resolve(42), promiseContext), 42)
assert.equal(promiseContext.result, 42)
assert.deepEqual(events.map(value => value[0]), ['start', 'end', 'asyncStart', 'asyncEnd'])
traced.unsubscribe(handlers)
console.log('native diagnostics retention, replacement, stores, errors and tracing passed')
