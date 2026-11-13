'use strict';
const util = require('node:util');
const options = {
  verbose: {type: 'boolean', short: 'v'}, quiet: {type: 'boolean', short: 'q', multiple: true},
  output: {type: 'string', short: 'o'}, include: {type: 'string', short: 'I', multiple: true},
  defaulted: {type: 'boolean', default: true}, paths: {type: 'string', multiple: true, default: ['fallback']},
};
const cases = [];
function add(name, config) { cases.push({name, config}); }
const vectors = [[], ['--verbose'], ['-v'], ['-vvq'], ['--output', 'file'], ['--output=file'], ['-ofile'], ['-o', 'file'], ['-vofile'], ['--output='], ['-o', ''], ['--output', '-'], ['--output', '-file'], ['--output', '--verbose'], ['--output'], ['-o'], ['--verbose=yes'], ['-v=yes'], ['--missing'], ['--missing=value'], ['-xyz'], ['--'], ['--', '-v', '--output=x', 'file'], ['file'], [''], ['-'], ['--include=a', '-Ib', '--include', 'c'], ['--quiet', '-q', '--quiet=false'], ['--verbose', '--no-verbose', '--verbose'], ['--no-verbose'], ['--no-missing'], ['--no-output'], ['--no-verbose=false'], ['--defaulted', '--no-defaulted'], ['--paths='], ['--__proto__=safe'], ['--constructor=x'], ['--=x'], ['---x'], ['-o--value'], ['--output=--'], ['--output', '--'], ['-Ione', '--include=two', 'tail']];
for (let i = 0; i < vectors.length; i++) {
  for (const strict of [true, false]) for (const allowNegative of [false, true]) {
    add('argv-' + i + '-' + strict + '-' + allowNegative, {args: vectors[i], options, strict, allowNegative, tokens: true});
  }
}
const invalid = [
  {args: null}, {args: {}}, {args: 'x'}, {args: [1]}, {args: [null]},
  {strict: null}, {strict: 1}, {allowPositionals: 1}, {allowNegative: 1}, {tokens: 1},
  {options: null}, {options: []}, {options: {x: null}}, {options: {x: []}}, {options: {x: {}}},
  {options: {x: {type: 'number'}}}, {options: {x: {type: 'boolean', multiple: 1}}},
  {options: {x: {type: 'boolean', short: 1}}}, {options: {x: {type: 'boolean', short: ''}}},
  {options: {x: {type: 'boolean', short: 'xx'}}}, {options: {x: {type: 'boolean', short: '😀'}}},
  {options: {x: {type: 'boolean', default: 'x'}}}, {options: {x: {type: 'string', default: false}}},
  {options: {x: {type: 'string', multiple: true, default: 'x'}}},
  {options: {x: {type: 'string', multiple: true, default: [1]}}},
];
for (let i = 0; i < invalid.length; i++) add('invalid-' + i, {args: [], ...invalid[i]});
add('no-tokens', {args: ['-v', '--output=x'], options});
add('positionals', {args: ['file', '-', '--', '--verbose'], options, allowPositionals: true, tokens: true});
add('duplicate-short', {args: ['-x'], options: {first: {type: 'boolean', short: 'x'}, second: {type: 'boolean', short: 'x'}}, tokens: true});
add('negative-declared', {args: ['--no-flag'], options: {flag: {type: 'boolean'}, 'no-flag': {type: 'boolean'}}, allowNegative: true, tokens: true});
add('special-names', {args: ['--__proto__=ok', '--constructor', 'safe'], options: JSON.parse('{"__proto__":{"type":"string"},"constructor":{"type":"string"}}'), tokens: true});
add('default-order', {args: ['--b=x'], options: {a: {type: 'string', default: 'a'}, b: {type: 'string'}, c: {type: 'boolean', default: false}}, tokens: true});
add('explicit-false', {args: ['--no-defaulted'], options, allowNegative: true});
add('unknown-config-field', {args: [], futureConfig: 'ignored'});
// The unchanged Bun runner's argument schema, exercised without scheduling tests.
add('consumer-runner-arguments', {args: ['--node-tests', '--exec-path', '/actual/tool', '--include=a', '--include', 'b', '--shard=2', 'test/example.test.ts'], allowPositionals: true, options: {'node-tests': {type: 'boolean', default: false}, 'exec-path': {type: 'string', default: 'bun'}, step: {type: 'string'}, 'build-id': {type: 'string'}, bail: {type: 'boolean', default: false}, shard: {type: 'string', default: '0'}, 'max-shards': {type: 'string', default: '1'}, include: {type: 'string', multiple: true}, exclude: {type: 'string', multiple: true}}});
for (const key of ['args', 'options', 'strict', 'allowPositionals', 'allowNegative', 'tokens']) add('nullable-' + key, {args: [], [key]: null});
for (const name of ['flag', 'name']) for (const allowNegative of [true, false]) {
  add('negative-value-' + name + '-' + allowNegative, {args: ['--no-' + name + '=x'], options: {flag: {type: 'boolean'}, name: {type: 'string'}}, allowNegative, tokens: true});
}
add('empty-multiple-default', {args: [], options: {x: {type: 'boolean', multiple: true, default: []}}});
add('boolean-multiple-default', {args: [], options: {x: {type: 'boolean', multiple: true, default: [false, true]}}});
add('boolean-multiple-explicit', {args: ['--x', '--no-x'], options: {x: {type: 'boolean', multiple: true, default: [true]}}, allowNegative: true, tokens: true});
add('unicode-short', {args: ['-é'], options: {enabled: {type: 'boolean', short: 'é'}}, tokens: true});
function observe(test) {
  const before = JSON.stringify(test.config);
  try {
    const result = util.parseArgs(test.config);
    return {name: test.name, result, resultKeys: Object.keys(result), valueKeys: Object.keys(result.values), nullPrototype: Object.getPrototypeOf(result.values) === null, tokenKeys: result.tokens ? result.tokens.map(token => Object.keys(token)) : null, inputUnchanged: before === JSON.stringify(test.config)};
  } catch (error) { return {name: test.name, error: {name: error.name, code: error.code || null}, inputUnchanged: before === JSON.stringify(test.config)}; }
}
if (typeof util.parseArgs !== 'function') console.log(JSON.stringify({available: false, expectedCases: cases.length, executed: 0, records: []}));
else {
  const records = cases.map(observe);
  // Exercise real process.argv defaults and public module/function identity.
  const previous = process.argv;
  process.argv = ['runtime', 'fixture', '--value=x'];
  const defaults = util.parseArgs({options: {value: {type: 'string'}}});
  process.argv = previous;
  console.log(JSON.stringify({available: true, expectedCases: cases.length, executed: records.length, records, controls: {functionName: util.parseArgs.name, functionLength: util.parseArgs.length, moduleIdentity: require('util') === util, argvDefaults: defaults, defaultNullPrototype: Object.getPrototypeOf(defaults.values) === null}}));
}
