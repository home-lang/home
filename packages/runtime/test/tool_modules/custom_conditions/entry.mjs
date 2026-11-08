import selected from '@home/custom-conditions';
import priority from '@home/custom-conditions/priority';
import nested from '@home/custom-conditions/nested';
import literal from '@home/custom-conditions/literal';
import { createRequire } from 'node:module';
const mode = process.argv[2];
const expected = mode === 'dev' ? 'dev' : 'prod';
if (selected !== expected) throw new Error('static import condition: ' + selected);
const localRequire = createRequire(import.meta.url);
if (localRequire('@home/custom-conditions') !== expected) throw new Error('require condition');
if (!localRequire.resolve('@home/custom-conditions').endsWith('/' + expected + '.cjs')) throw new Error('require.resolve condition');
const dynamic = await import('@home/custom-conditions');
if (dynamic.default !== expected || dynamic !== await import('@home/custom-conditions')) throw new Error('dynamic import/cache condition');
if (priority !== (mode === 'dev' ? 'second' : 'prod')) throw new Error('JSON condition order');
if (nested !== 'prod') throw new Error('unmatched nested condition');
if (literal !== (mode === 'literal' ? 'literal' : 'prod')) throw new Error('comma condition must stay literal');
let blocked = false;
try {
  const value = await import('@home/custom-conditions/blocked');
  if (value.default !== 'prod') throw new Error('default target');
}
catch (error) {
  if (error.code !== 'ERR_PACKAGE_PATH_NOT_EXPORTED') throw error;
  blocked = true;
}
if (blocked !== (mode === 'dev')) throw new Error('null condition blocking');
globalThis.__home_tool_conditions = mode === 'dev' ? '[]' : '["development"]';
if ((await import('@home/custom-conditions/late')).default !== expected) throw new Error('public state changed conditions');
if (process.argv[3] !== '--conditions' || process.argv[4] !== 'argument-value') throw new Error('entry arguments were consumed as flags');
console.log('OK actual custom package conditions ' + mode);
