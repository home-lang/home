var path = 'logs', defaults = { value: 2, path }, config = { ...defaults }, ready = (async () => {
  await Promise.resolve();
  config.value += 1;
  return config;
})();
class Reader {
  read() { return { ...config }; }
}
if (new Reader().read().value !== 2 || config.path !== path) throw new Error('async initializer stole module siblings');
let one = 1, two = 2, read = function () { return two; };
if (one + two !== 3 || read() !== 2) throw new Error('function initializer stole siblings');
const a = 1, b = 2, C = class { read() { return b; } };
if (a + b !== 3 || new C().read() !== 2) throw new Error('class initializer stole siblings');
function nested() {
  var first = 1, second = 2, fn = () => {
    let inner = 3, other = 4, empty = () => {};
    return inner + other + second + (empty() === undefined ? 0 : 100);
  };
  return first + second + fn();
}
if (nested() !== 12) throw new Error('recursive declaration ownership changed');
const result = await ready;
if (result !== config || config.value !== 3 || defaults.value !== 2) throw new Error('async sibling identity changed');
console.log('OK actual nested declaration scope and initialization');
