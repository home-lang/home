import assert, { ok, strictEqual, notStrictEqual, AssertionError } from 'node:assert';
import alias from 'assert';
import { createRequire } from 'node:module';
if (alias !== assert || ok !== assert.ok || strictEqual !== assert.strictEqual || notStrictEqual !== assert.notStrictEqual || AssertionError !== assert.AssertionError) throw new Error('assert ESM alias or export identity');
strictEqual(17,17);
notStrictEqual(0,-0);
createRequire(import.meta.url)('./assert_core.cjs');
