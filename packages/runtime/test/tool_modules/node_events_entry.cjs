const EventEmitter = require('node:events');
const output = {};
function check(condition, message) { if (!condition) throw new Error(message); }
check(EventEmitter === require('events') && EventEmitter.EventEmitter === EventEmitter, 'events module identity');
check(process instanceof EventEmitter, 'process emitter identity');
const emitter = new EventEmitter();
const trace = [];
function first(value) { check(this === emitter, 'listener receiver'); trace.push('first:' + value); }
function last(value) { trace.push('last:' + value); }
emitter.on('data', first).prependOnceListener('data', function(value) { trace.push('once:' + value); }).on('data', last);
check(emitter.rawListeners('data')[0].listener === emitter.listeners('data')[0], 'raw once wrapper');
check(emitter.emit('data', 1) === true && emitter.emit('missing') === false, 'emit result');
emitter.emit('data', 2);
output.order = trace;
const duplicate = new EventEmitter();
function repeated() {}
duplicate.on('x', repeated).once('x', repeated).on('x', repeated);
check(duplicate.listenerCount('x', repeated) === 3, 'duplicate count');
duplicate.removeListener('x', repeated);
check(duplicate.rawListeners('x')[1].listener === repeated, 'removal must remove last matching registration');
duplicate.removeListener('x', repeated);
check(duplicate.rawListeners('x')[0] === repeated && duplicate.listenerCount('x') === 1, 'remove once by original');
output.duplicates = duplicate.listenerCount('x');
const mutation = new EventEmitter();
const mutations = [];
function removed() { mutations.push('removed still in snapshot'); }
mutation.on('x', function() { mutations.push('first'); mutation.off('x', removed); mutation.on('x', () => mutations.push('later')); });
mutation.on('x', removed);
mutation.emit('x');
output.mutation = mutations;
const nested = new EventEmitter();
let nestedOnce = 0;
nested.on('x', function(value) { if (value === 0) nested.emit('x', 1); });
nested.once('x', function() { nestedOnce++; });
nested.emit('x', 0);
check(nestedOnce === 1, 'once wrapper retained by an outer dispatch snapshot');
const inserted = new EventEmitter();
const insertedTrace = [];
inserted.once('newListener', function(type) { if (type === 'x') inserted.on('x', () => insertedTrace.push('inserted')); });
inserted.on('x', () => insertedTrace.push('original'));
inserted.emit('x');
output.inserted = insertedTrace;
const protoKey = new EventEmitter();
protoKey.on('__proto__', repeated);
check(protoKey.listenerCount('__proto__') === 1 && protoKey.emit('__proto__'), 'prototype-safe event name');
protoKey.removeAllListeners('__proto__');
const reentrant = new EventEmitter();
let calls = 0;
reentrant.once('x', function() { calls++; reentrant.emit('x'); });
reentrant.emit('x');
check(calls === 1, 'once reentrancy');
const manual = new EventEmitter();
manual.once('x', function() { check(this === manual, 'raw once receiver'); calls++; });
const wrapper = manual.rawListeners('x')[0];
wrapper.call({}); wrapper();
check(calls === 2 && manual.listenerCount('x') === 0, 'raw once fires once');
const meta = new EventEmitter();
const metadata = [];
function member() {}
meta.on('newListener', (name, fn) => { if (name === 'value') metadata.push(['add', fn === member, meta.listenerCount(name)]); });
meta.on('removeListener', (name, fn) => { if (name === 'value') metadata.push(['remove', fn === member, meta.listenerCount(name)]); });
meta.once('value', member);
meta.emit('value');
output.metadata = metadata;
const removal = new EventEmitter();
const removeOrder = [];
function one() {} function two() {}
removal.on('removeListener', (name, fn) => { if (name === 'x') removeOrder.push(fn === two ? 'two' : 'one'); });
removal.on('x', one).on('x', two);
removal.removeAllListeners();
check(removal.eventNames().length === 0, 'remove all');
output.removeOrder = removeOrder;
const symbol = Symbol('event');
const symbols = new EventEmitter();
symbols.once(symbol, value => { output.symbol = value; });
check(symbols.eventNames()[0] === symbol, 'symbol event name');
symbols.emit(symbol, 42);
check(symbols.eventNames().length === 0, 'empty event buckets removed');
const error = new Error('identity witness');
let observed;
try { new EventEmitter().emit('error', error); } catch (caught) { observed = caught; }
check(observed === error, 'unhandled error identity');
observed = undefined;
try { new EventEmitter().emit('error', 'payload'); } catch (caught) { observed = caught; }
check(observed && observed.code === 'ERR_UNHANDLED_ERROR' && observed.context === 'payload', 'unhandled non-error payload');
const monitored = new EventEmitter();
const monitor = [];
monitored.on(EventEmitter.errorMonitor, value => monitor.push(value === error));
monitored.on('error', value => monitor.push(value === error));
monitored.emit('error', error);
output.monitor = monitor;
const thrown = {};
const throwing = new EventEmitter();
throwing.on('x', () => { throw thrown; });
observed = undefined;
try { throwing.emit('x'); } catch (caught) { observed = caught; }
check(observed === thrown, 'listener exceptions propagate');
for (const n of [-1, NaN]) {
  observed = undefined;
  try { emitter.setMaxListeners(n); } catch (caught) { observed = caught; }
  check(observed && observed.code === 'ERR_OUT_OF_RANGE', 'max validation');
}
observed = undefined;
try { emitter.on('x', 123); } catch (caught) { observed = caught; }
check(observed && observed.code === 'ERR_INVALID_ARG_TYPE', 'listener validation');
const initial = EventEmitter.defaultMaxListeners;
EventEmitter.defaultMaxListeners = 17;
check(new EventEmitter().getMaxListeners() === 17, 'default maximum');
EventEmitter.defaultMaxListeners = initial;
check(emitter.setMaxListeners(1.5).getMaxListeners() === 1.5 && emitter.setMaxListeners(Infinity).getMaxListeners() === Infinity, 'real max setting');
const inherited = new (class extends EventEmitter {})();
check(inherited.on('x', first) === inherited, 'subclass chaining');
function Legacy() { EventEmitter.call(this); }
Object.setPrototypeOf(Legacy.prototype, EventEmitter.prototype);
check(new Legacy().on('x', repeated).listenerCount('x') === 1, 'legacy constructor');
const registrationCalls = [];
class ObservedEmitter extends EventEmitter {
  on(type, listener) {
    registrationCalls.push(['on', typeof listener.listener === 'function']);
    super.on(type, listener);
    return 'override';
  }
  prependListener(type, listener) {
    registrationCalls.push(['prepend', typeof listener.listener === 'function']);
    super.prependListener(type, listener);
    return 'override';
  }
}
const observedEmitter = new ObservedEmitter();
check(observedEmitter.once('x', repeated) === observedEmitter && observedEmitter.prependOnceListener('x', repeated) === observedEmitter, 'once honors virtual registration without changing chaining');
output.registrationCalls = registrationCalls;
const rawOverride = new EventEmitter();
rawOverride.on('x', repeated);
rawOverride.rawListeners = () => [];
check(rawOverride.listeners('x')[0] === repeated, 'listeners must not dispatch through rawListeners override');
const warnings = [];
const warningEmitter = new EventEmitter().setMaxListeners(1);
function warningListener(warning) { if (warning.emitter === warningEmitter) warnings.push([warning.name, warning.type, warning.count]); }
process.on('warning', warningListener);
warningEmitter.on('warn', repeated).on('warn', repeated).on('warn', repeated);
process.nextTick(() => {
  process.off('warning', warningListener);
  check(warnings.length === 1, 'actual maximum-listener warning');
  output.warnings = warnings;
  console.log(JSON.stringify(output));
});
