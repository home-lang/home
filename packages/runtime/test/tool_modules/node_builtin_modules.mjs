import Module, { builtinModules, createRequire, isBuiltin } from 'node:module';
const requireHere = createRequire(import.meta.url);
const common = requireHere('./node_builtin_modules.cjs');
let completed = 0;
function check(label, condition) {
  if (!condition) throw new Error(label + '; completed ' + completed + ' ESM builtin module checks');
  completed++;
}
check('named/default/CJS snapshot identity', builtinModules === Module.builtinModules && builtinModules === common.names);
check('named function identity', isBuiltin === Module.isBuiltin && createRequire === Module.createRequire);
check('module has one loader identity', Module === requireHere('module') && Module === requireHere('node:module'));
check('snapshot remains frozen', Object.isFrozen(builtinModules));
check('unknown builtin is refused', !isBuiltin('node:__home_not_a_builtin__') && !isBuiltin('__home_not_a_builtin__'));
check('non-string values are not builtin names', [null, undefined, 1, {}, []].every(value => !isBuiltin(value)));
check('names are reusable iterable data', [...builtinModules].join() === builtinModules.join());
console.log('ESM BUILTIN MODULES ' + completed + ' CHECKS OK');
if (process.argv.includes('--home-profile')) {
  let loaded = 0;
  const cacheBefore = Object.keys(requireHere.cache).sort().join();
  for (const name of builtinModules) {
    const value = requireHere(name);
    if ((typeof value !== 'object' || value === null) && typeof value !== 'function') throw new Error('missing actual namespace ' + name);
    if (requireHere.resolve(name) !== name) throw new Error('builtin resolved to a file ' + name);
    if (!name.startsWith('node:') && value !== requireHere('node:' + name)) throw new Error('alias mismatch ' + name);
    loaded++;
  }
  if (Object.keys(requireHere.cache).sort().join() !== cacheBefore) throw new Error('builtin loads forged file cache entries');
  // These unavailable modules must remain absent from both discovery and the
  // actual loader. This is a registered namespace inventory, not full Node API
  // compatibility within each namespace.
  for (const name of ['http', 'https', 'tls', 'worker_threads', 'inspector', 'bun:sqlite', 'bun:test']) {
    if (builtinModules.includes(name) || builtinModules.includes('node:' + name) || isBuiltin(name)) throw new Error('unavailable Node builtin advertised ' + name);
    if (!name.startsWith('bun:')) {
      let refused = false;
      try { requireHere('node:' + name); }
      catch { refused = true; }
      if (!refused) throw new Error('unsupported namespace unexpectedly loaded ' + name);
    }
  }
  if (loaded !== builtinModules.length || loaded === 0) throw new Error('incomplete actual namespace loads');
  console.log('HOME BUILTIN INVENTORY ALL REAL NAMES LOADED; REFUSALS OK');
}
