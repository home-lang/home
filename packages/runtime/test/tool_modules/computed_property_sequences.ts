const events = [];
function key(label) { events.push(label); return label; }
let tag;
class Example {
  [(tag = Symbol.toStringTag, Symbol.iterator)]() { return 31; }
  static [(key('static'), 'method')]() { return 32; }
  [(key('field'), 'field')] = 33;
  get [(key('getter'), 'value')]() { return this.field + 1; }
  set [(key('setter'), 'value')](value) { this.field = value; }
}
const instance = new Example();
const object = {
  [(key('property'), 'property')]: 35,
  [(key('method'), 'method')]() { return 36; },
  get [(key('object-getter'), 'value')]() { return this.property + 2; },
  set [(key('object-setter'), 'value')](value) { this.property = value; },
};
const { [(key('binding'), 'property')]: selected } = object;
if (tag !== Symbol.toStringTag || instance[Symbol.iterator]() !== 31 || Example.method() !== 32 || instance.value !== 34 || selected !== 35 || object.method() !== 36 || object.value !== 37) throw new Error('computed values');
instance.value = 38;
object.value = 39;
if (instance.field !== 38 || object.property !== 39) throw new Error('computed setters');
if (events.join(',') !== 'static,field,getter,setter,property,method,object-getter,object-setter,binding') throw new Error('computed order: ' + events.join(','));
console.log('OK computed sequence keys, getters, setters, fields and binding order');
