"use strict";
const snapshot = [defaultValue, named, namespace.label];
let checks = 0;
const failures = [];
function equal(actual, expected) {
  checks++;
  if (JSON.stringify(actual) !== JSON.stringify(expected)) failures.push({ check: checks, actual: JSON.stringify(actual) ?? String(actual), expected: JSON.stringify(expected) ?? String(expected) });
}
equal(snapshot, [11, 22, 'namespace']);
equal(plusOne(3), 4);
equal(globalThis.lateImportTrace, ['bindings', 'namespace', 'effect']);
equal(this, undefined);
equal(alias, named);
let immutable = false;
try {
  // eslint-disable-next-line no-import-assign
  named = 0;
}
catch (error) {
  immutable = error instanceof TypeError;
}
equal(immutable, true);
function shadow(named) { return named; }
equal(shadow(5), 5);
equal(typeof globalThis.named, 'undefined');
const require = createRequire(import.meta.url);
globalThis.lateImportTrace.push('before require');
const required = require('./required.cjs');
equal(required.value, 73);
equal(globalThis.lateImportTrace, ['bindings', 'namespace', 'effect', 'before require', 'require']);
equal(require('./required.cjs') === required, true);
const typed = await import('./typed.mts');
equal(typed.result, 23);
equal(globalThis.lateImportTrace.length, 5);
const awaited = await import('./awaited.mjs');
equal(awaited.result, 24);
let failure;
try { await import('./failure-entry.mjs'); }
catch (error) { failure = error; }
equal(failure === globalThis.lateImportFailure, true);
equal(globalThis.lateImportFailureBody, undefined);
equal(failure.message, 'real dependency failure');
let repeated;
try { await import('./failure-entry.mjs'); }
catch (error) { repeated = error; }
equal(repeated === failure, true);
await import('./effect.mjs');
equal(globalThis.lateImportTrace.length, 5);
console.log('LATE STATIC IMPORT RESULTS ' + JSON.stringify({ checks, passed: checks - failures.length, failures }));
if (checks !== 19 || failures.length) throw new Error('Late import denominator or binding mismatch');
console.log('LATE STATIC IMPORT 19 CHECKS OK');
import defaultValue, { named, plusOne } from './bindings.mjs';
import { named as alias } from './bindings.mjs';
import * as namespace from './namespace.mjs';
import './effect.mjs';
import { createRequire } from 'node:module';
