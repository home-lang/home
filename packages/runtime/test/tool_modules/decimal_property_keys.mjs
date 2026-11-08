function check(value, message) { if (!value) throw new Error(message); }
const values = { '0.0000001': 1, '0.0000009': 2, '0.000001': 3, '0.000000000000000000001': 4, '1e-7': 5 };
check(values['0.0000001'] === 1 && values['0.0000009'] === 2 && values['0.000001'] === 3 && values['0.000000000000000000001'] === 4 && values['1e-7'] === 5, 'decimal string names must not become exponent keys');
const methods = { '0.0000001'() { return 6; } };
check(methods['0.0000001']() === 6, 'decimal method name');
class Example { '0.0000001'() { return 7; } }
check(new Example()['0.0000001']() === 7, 'decimal class method name');
const accessors = { get '0.0000001'() { return 8; } };
check(accessors['0.0000001'] === 8, 'decimal accessor name');
const numeric = { 0.0000001: 9 };
const computed = { [1e-7]: 10 };
check(numeric['1e-7'] === 9 && computed['1e-7'] === 10, 'actual Number property keys remain exponent strings');
console.log('OK exact decimal string keys and actual Number exponent keys');
