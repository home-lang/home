import vm, { runInThisContext } from 'node:vm';
import plain from 'vm';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const callerLexical = 'private caller';
let checks = 0;
function check(value, name) { if (!value) throw Error('VM Script mismatch: ' + name); checks++; }
check(vm === plain && vm.runInThisContext === runInThisContext, 'module aliases and named export');
check(runInThisContext('40 + 2') === 42, 'statement completion');
check(runInThisContext('') === undefined, 'empty completion');
check(runInThisContext('this === globalThis') === true, 'global receiver');
check(runInThisContext('typeof callerLexical') === 'undefined', 'caller lexical isolation');
check(runInThisContext('typeof require') === typeof globalThis.require, 'global require visibility');
check(runInThisContext('var __vmOwnVar = 31; __vmOwnVar') === 31 && globalThis.__vmOwnVar === 31, 'global var');
check(runInThisContext('let __vmOwnLex = 41; __vmOwnLex') === 41 && runInThisContext('__vmOwnLex + 1') === 42 && !Object.hasOwn(globalThis, '__vmOwnLex'), 'persistent global lexical');
let duplicate;
try { runInThisContext('let __vmOwnLex = 99'); } catch (error) { duplicate = error; }
check(duplicate instanceof SyntaxError, 'global lexical redeclaration');
let syntax;
try { runInThisContext('return 1', {displayErrors:false}); } catch (error) { syntax = error; }
check(syntax instanceof SyntaxError, 'Script grammar, not Function body');
globalThis.__vmOwnToken = { marker: 43 };
let caught;
try { runInThisContext('throw __vmOwnToken'); } catch (error) { caught = error; }
check(caught === globalThis.__vmOwnToken, 'thrown identity');
check(runInThisContext('"a\u0000b"') === 'a\u0000b', 'embedded NUL source');
check(runInThisContext({toString(){ return '6 * 7'; }}) === 42, 'observable source conversion');
const fn = runInThisContext('(function(exports, require, module, __filename, __dirname, jitiImport, jitiESMResolve){exports.filename=__filename;exports.local=typeof callerLexical;module.exports.value=require("node:path").join(__dirname,"config.js");return 7})', {filename:'/owned/config.js',lineOffset:0,displayErrors:false});
const module = {exports:{}};
check(fn(module.exports,require,module,'/owned/config.js','/owned',undefined,undefined) === 7 && module.exports.value === '/owned/config.js' && module.exports.filename === '/owned/config.js' && module.exports.local === 'undefined', 'actual jiti seven-argument invocation');
let filenameReads = 0;
check(runInThisContext('5', {get filename(){filenameReads++;return 'getter.js';},displayErrors:false}) === 5 && filenameReads === 1, 'single filename getter read');
check(String(runInThisContext('Error("string filename")', 'vm-string-filename.js').stack).includes('vm-string-filename.js'), 'filename string shorthand');
let named;
try { runInThisContext('throw Error("owned")', {filename:'vm-owned-probe.js',lineOffset:0,displayErrors:false}); } catch (error) { named = error; }
check(named instanceof Error && named.message === 'owned' && String(named.stack).includes('vm-owned-probe.js'), 'real filename diagnostic');
globalThis.__vmOwnTrace = [];
runInThisContext('Promise.resolve().then(()=>__vmOwnTrace.push("job"));__vmOwnTrace.push("inner")');
__vmOwnTrace.push('after');
check(__vmOwnTrace.join(',') === 'inner,after', 'nested job deferral');
await new Promise(resolve => setImmediate(resolve));
check(__vmOwnTrace.join(',') === 'inner,after,job', 'actual outer job checkpoint');
check(Reflect.deleteProperty(globalThis, '__vmOwnVar') === false, 'Script var is non-configurable');
delete globalThis.__vmOwnToken; delete globalThis.__vmOwnTrace;
if (checks !== 20) throw Error('VM Script denominator mismatch: ' + checks);
console.log('VM SCRIPT 20 CHECKS OK');
