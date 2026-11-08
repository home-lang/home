let count = 0;
const key = 'computed';
const first = { value: ++count, next: --count, [key]: ++count };
if (JSON.stringify(first) !== '{"value":1,"next":0,"computed":1}' || count !== 1) throw new Error('object update values or ordering changed');
function make() {
  let local = 4;
  return { up: ++local, down: --local, grouped: (++local) };
}
if (JSON.stringify(make()) !== '{"up":5,"down":4,"grouped":5}') throw new Error('function object update failed');
const cache = new Map();
if (cache.set('key', { lastAccess: ++count }), cache.size > 0) {
  if (cache.get('key').lastAccess !== 2) throw new Error('cache update failed');
}
else throw new Error('cache did not receive value');
console.log('OK actual object prefix update values and order');
