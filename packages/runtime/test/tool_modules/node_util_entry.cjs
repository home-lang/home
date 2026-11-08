const util = require('node:util');
if (util !== require('util')) throw new Error('util alias identity');
const inputs = require('./node_util_strings.json');
const outputs = inputs.map(text => util.stripVTControlCharacters(text));
// Repeated calls exercise the private recognizer's global lastIndex handling.
for (let index = 0; index < inputs.length; index++) {
  if (util.stripVTControlCharacters(inputs[index]) !== outputs[index]) throw new Error('recognizer state leaked');
}
const errors = [];
for (const value of [null, undefined, 1, 1n, true, Symbol('text'), {}, new String('text')]) {
  try {
    util.stripVTControlCharacters(value);
    throw new Error('non-string accepted');
  }
  catch (error) {
    if (error.code !== 'ERR_INVALID_ARG_TYPE') throw error;
    errors.push([error.name, error.code]);
  }
}
console.log(JSON.stringify({ outputs, errors }));
