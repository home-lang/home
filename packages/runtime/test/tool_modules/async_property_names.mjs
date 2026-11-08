function check(value, message) { if (!value) throw new Error(message); }
const key = Symbol('computed');
const methods = {
  async delete(value) { return await Promise.resolve(value); },
  async class() { return 2; },
  async default() { return 3; },
  async await() { return 4; },
  async typeof() { return 5; },
  async 'quoted key'() { return 6; },
  async 16() { return 7; },
  async 1n() { return 8; },
  async [key]() { return 9; },
  async() { return 10; },
};
check(JSON.stringify(await Promise.all([methods.delete(1), methods.class(), methods.default(), methods.await(), methods.typeof(), methods['quoted key'](), methods[16](), methods[1](), methods[key]()])) === '[1,2,3,4,5,6,7,8,9]', 'actual async property bodies');
check(methods.async() === 10, 'ordinary method named async');
const exact = {
  async 0x20_0000_0000_0001n() { return 1; },
  async 0b1_001n() { return 2; },
  async 0o2_7n() { return 3; },
  async 9999999999999999999999999999999999999999n() { return 4; },
};
check(JSON.stringify(await Promise.all([exact['9007199254740993'](), exact[9](), exact[23](), exact['9999999999999999999999999999999999999999']()])) === '[1,2,3,4]', 'exact bigint keys without precision loss');
const strings = { '01': 1, '1.0': 2, '1e5': 3, '9007199254740993': 4 };
check(strings['01'] === 1 && strings['1.0'] === 2 && strings['1e5'] === 3 && strings['9007199254740993'] === 4, 'exact numeric-looking string names');
const generator = { async *delete(value) { yield await Promise.resolve(value); } };
const iterator = generator.delete(11);
const first = await iterator.next();
const last = await iterator.next();
check(first.value === 11 && first.done === false && last.value === undefined && last.done === true, 'async generator keyword method');
console.log('OK actual async keyword, literal, computed and generator methods');
