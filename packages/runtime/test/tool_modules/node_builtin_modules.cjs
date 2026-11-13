'use strict';
const Module = require('node:module');
let completed = 0;
function check(label, condition) {
  if (!condition) throw new Error(label + '; completed ' + completed + ' builtin module checks');
  completed++;
}
const names = Module.builtinModules;
check('nonempty builtin module array', Array.isArray(names) && names.length > 0);
check('string names', names.every(name => typeof name === 'string' && name.length > 0));
check('unique names', new Set(names).size === names.length);
check('frozen list', Object.isFrozen(names));
check('module aliases share the list', require('module').builtinModules === names && Module.Module.builtinModules === names);
const descriptor = Object.getOwnPropertyDescriptor(Module, 'builtinModules');
check('ordinary replaceable export', descriptor.value === names && descriptor.enumerable && descriptor.writable && descriptor.configurable);
check('advertised names are builtin', names.every(name => Module.isBuiltin(name)));
check('Bun namespaces are not Node builtin names', !names.some(name => name === 'bun' || name.startsWith('bun:'))
  && ['bun', 'bun:sqlite', 'bun:test'].every(name => !Module.isBuiltin(name)));
// These namespaces already have owned implementations. Exercise actual loads,
// alias identity and resolution, rather than accepting a names-only facade.
const required = [
  'assert', 'assert/strict', 'buffer', 'child_process', 'crypto', 'dns/promises',
  'events', 'fs', 'fs/promises', 'module', 'net', 'os', 'path', 'path/posix',
  'path/win32', 'perf_hooks', 'process', 'readline', 'stream', 'stream/promises',
  'string_decoder', 'timers', 'timers/promises', 'tty', 'url', 'util', 'util/types',
  'v8', 'vm', 'zlib',
];
for (const name of required) {
  check('actual builtin namespace ' + name, names.includes(name)
    && !names.includes('node:' + name)
    && Module.isBuiltin(name) && Module.isBuiltin('node:' + name)
    && require(name) === require('node:' + name)
    && require.resolve(name) === name && require.resolve('node:' + name) === 'node:' + name);
}
let mutationError;
try { names.push('__home_not_a_builtin__'); }
catch (error) { mutationError = error; }
check('frozen array rejects mutation', mutationError instanceof TypeError && !names.includes('__home_not_a_builtin__'));
Module.builtinModules = ['__home_not_a_builtin__'];
check('replacing introspection does not register a module', !Module.isBuiltin('__home_not_a_builtin__'));
let missing;
try { require('node:__home_not_a_builtin__'); }
catch (error) { missing = error; }
check('unregistered module really refuses to load', !!missing && !Object.keys(require.cache).some(name => name.includes('__home_not_a_builtin__')));
Module.builtinModules = names;
check('loader and original snapshot survive replacement', require('path') === require('node:path') && Module.builtinModules === names);
console.log('NODE BUILTIN MODULES ' + completed + ' CHECKS OK');
module.exports = { names, completed };
