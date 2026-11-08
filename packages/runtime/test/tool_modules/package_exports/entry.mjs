import root from '@home/exports';
import cache from '@home/exports/cache';
import { cache as reexported } from './reexport.mjs';
import feature from '@home/exports/feature/value';
import special from '@home/exports/feature/special/value';
import json from '@home/exports/feature/value.json';
import exact from '@home/exports/exact';
import { createRequire } from 'node:module';
const req = createRequire(import.meta.url);
if (cache !== reexported) throw new Error("re-export changed resolution condition");
const values = [root, cache, feature, special, json, exact, req('@home/exports'), req('@home/exports/feature/value'), req('@home/exports/nested'), req('@home/exports/ordered'), req('@home/exports/array'), req('@home/exports/self'), req('@home/string'), req('@home/null')];
if (JSON.stringify(values) !== JSON.stringify(['import','cache','feature','special','json','exact','require','require','nested','default','array','require','string','string'])) throw new Error('package exports selected wrong target: ' + JSON.stringify(values));
if (req.resolve('@home/exports') !== req.resolve('@home/exports/self').replace('/self.cjs', '/require.cjs')) throw new Error('lookup differs from execution');
const cases = [
 ['@home/exports/cache', 'ERR_PACKAGE_PATH_NOT_EXPORTED'],
 ['@home/exports/blocked', 'ERR_PACKAGE_PATH_NOT_EXPORTED'],
 ['@home/exports/private/value', 'ERR_PACKAGE_PATH_NOT_EXPORTED'],
 ['@home/exports/bad', 'ERR_INVALID_PACKAGE_TARGET'],
 ['@home/exports/traversal', 'ERR_INVALID_PACKAGE_TARGET'],
 ['@home/exports/encoded', 'ERR_INVALID_PACKAGE_TARGET'],
 ['@home/exports/encoded-separator', 'ERR_INVALID_MODULE_SPECIFIER'],
 ['@home/exports/invalid-value', 'ERR_INVALID_PACKAGE_TARGET'],
 ['@home/string/private.cjs', 'ERR_PACKAGE_PATH_NOT_EXPORTED'],
 ['@home/mixed', 'ERR_INVALID_PACKAGE_CONFIG'],
 ['@home/numeric', 'ERR_INVALID_PACKAGE_CONFIG'],
];
for (const [name, code] of cases) {
 let caught;
 try { req.resolve(name); } catch (error) { caught = error; }
 if (!caught || caught.code !== code) throw new Error(name + ': expected ' + code + ', got ' + (caught && caught.code));
}
for (const name of ['@home/exports/missing-array', '@home/exports/extensionless', '@home/exports/directory']) {
 let caught;
 try { req.resolve(name); } catch (error) { caught = error; }
 if (!caught) throw new Error('exports performed a filesystem fallback: ' + name);
}
const asset = req.resolve('@home/exports/asset');
if (!asset.endsWith('/asset.txt') || asset in req.cache) throw new Error('lookup executed asset');
console.log('OK actual package exports conditions, patterns and blocked targets');
