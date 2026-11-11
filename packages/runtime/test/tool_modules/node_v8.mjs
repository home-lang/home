import * as api from 'node:v8';
import { runValueContract } from './v8_values.mjs';
const result = runValueContract(api);
console.log('V8 BINARY RESULTS ' + JSON.stringify(result));
if (result.failures.length) throw new Error('Real binary serialization contract failed');
console.log('V8 BINARY ' + result.groups + ' GROUPS OK');
