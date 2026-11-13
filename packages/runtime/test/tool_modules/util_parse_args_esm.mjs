import util, {parseArgs} from 'node:util';
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
const parsed = parseArgs({args: ['-vv', '--name=real', '--', '--ignored'], options: {verbose: {type: 'boolean', short: 'v', multiple: true}, name: {type: 'string'}}, allowPositionals: true, tokens: true});
console.log(JSON.stringify({same: parseArgs === util.parseArgs && require('util') === util, nullPrototype: Object.getPrototypeOf(parsed.values) === null, parsed}));
