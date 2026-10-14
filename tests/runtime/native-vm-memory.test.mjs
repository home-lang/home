import assert from 'node:assert/strict'
import vm from 'node:vm'
import { spawnSync } from 'node:child_process'
import { Worker } from 'node:worker_threads'

function bounds(range) {
  assert.equal(typeof range.jsMemoryEstimate, 'number')
  assert(range.jsMemoryEstimate >= 0)
  assert(range.jsMemoryRange[0] <= range.jsMemoryEstimate)
  assert(range.jsMemoryEstimate <= range.jsMemoryRange[1])
}

async function main() {
  for (const property of ['name', 'origin', 'codeGeneration', 'microtaskMode', 'importModuleDynamically']) {
    const getterError = new Error(property)
    assert.throws(() => vm.createContext({}, {
      get [property]() { throw getterError },
    }), error => error === getterError)
  }
  const wasmBytes = Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
  for (const run of [
    (code, flags) => vm.runInContext(code, vm.createContext({ wasmBytes }, { codeGeneration: flags })),
    (code, flags) => vm.runInNewContext(code, { wasmBytes }, { contextCodeGeneration: flags }),
    (code, flags) => new vm.Script(code).runInNewContext({ wasmBytes }, { contextCodeGeneration: flags }),
  ]) {
    for (const flags of [{}, { strings: undefined, wasm: undefined }, { strings: true }, { wasm: true }]) {
      assert.equal(run('eval("6 * 7")', flags), 42)
      assert.equal(run('new WebAssembly.Module(wasmBytes) instanceof WebAssembly.Module', flags), true)
    }
    assert.throws(() => run('eval("6 * 7")', { strings: false, wasm: undefined }), { name: 'EvalError' })
    assert.throws(() => run('new WebAssembly.Module(wasmBytes)', { strings: undefined, wasm: false }), { name: 'CompileError' })
    for (const flag of ['strings', 'wasm']) {
      for (const value of [null, 0, 'true']) {
        assert.throws(() => run('42', { [flag]: value }), { code: 'ERR_INVALID_ARG_TYPE' })
      }
    }
    const flagReads = []
    const flagGetterError = new Error('wasm flag getter')
    assert.throws(() => run('42', {
      get strings() { flagReads.push('strings'); return 0 },
      get wasm() { flagReads.push('wasm'); throw flagGetterError },
    }), error => error === flagGetterError)
    assert.deepEqual(flagReads, ['strings', 'wasm'])
  }
  const reuse = spawnSync(process.execPath, ['-e', `
    const assert = require('node:assert/strict');
    const vm = require('node:vm');
    const sandbox = {};
    new vm.Script('let retainedLexical=40;globalThis.realmObject=Object;undefined').runInNewContext(sandbox);
    assert.equal(vm.isContext(sandbox), true);
    assert.equal(new vm.Script('retainedLexical+2').runInNewContext(sandbox), 42);
    assert.equal(vm.runInContext('retainedLexical+2', sandbox), 42);
    assert.equal(new vm.Script('Object===realmObject').runInNewContext(sandbox), true);
    const already = vm.createContext({});
    vm.runInContext('let existingLexical=7', already);
    assert.equal(vm.runInNewContext('existingLexical', already), 7);
    const checkpoint = vm.createContext({ value: 0 }, { microtaskMode: 'afterEvaluate' });
    new vm.Script('Promise.resolve().then(() => value++)').runInNewContext(checkpoint);
    assert.equal(checkpoint.value, 1);
    let reads = 0;
    const ignored = { get name() { reads++; return 'unused'; }, get microtaskMode() { reads++; return 'afterEvaluate'; } };
    assert.equal(vm.createContext(already, ignored), already);
    assert.equal(reads, 0);
    assert.equal(vm.createContext(already, null), already);
    for (const run of [(code, options) => vm.runInNewContext(code, {}, options), (code, options) => new vm.Script(code).runInNewContext({}, options)]) {
      assert.equal(run('2+2', { name: 17, origin: 19 }), 4);
      assert.throws(() => run('2+2', { contextName: 17 }), { code: 'ERR_INVALID_ARG_TYPE' });
      assert.throws(() => run('2+2', { contextOrigin: 19 }), { code: 'ERR_INVALID_ARG_TYPE' });
    }
    assert.throws(() => vm.createContext({}, { importModuleDynamically: 17 }), { code: 'ERR_INVALID_ARG_TYPE' });
    const extensionContext = vm.createContext({ outside: 7 });
    const extension = { inside: 40 };
    const compiled = vm.compileFunction('return inside+outside', [], { parsingContext: extensionContext, contextExtensions: [extension] });
    assert.equal(compiled(), 47);
    assert.equal(Object.getPrototypeOf(compiled), vm.runInContext('Function.prototype', extensionContext));
    assert.equal(vm.runInContext('typeof inside', extensionContext), 'undefined');
    assert.equal(vm.compileFunction('return typeof inside', [], { parsingContext: extensionContext })(), 'undefined');
    extension.inside = 50;
    assert.equal(compiled(), 57);
    const special = vm.createContext(vm.constants.DONT_CONTEXTIFY);
    special.value = 42;
    assert.equal(vm.compileFunction('return value', [], { parsingContext: special })(), 42);
    assert.throws(() => vm.compileFunction('return 1', [], { importModuleDynamically: 17 }), { code: 'ERR_INVALID_ARG_TYPE' });
    assert.throws(() => vm.compileFunction('return 1', [], 'filename.js'), { code: 'ERR_INVALID_ARG_TYPE' });
    assert.throws(() => vm.compileFunction('return 1', [], []), { code: 'ERR_INVALID_ARG_TYPE' });
    assert.throws(() => vm.compileFunction('return 1', [], { contextExtensions: [{}, 17] }), error => error.code === 'ERR_INVALID_ARG_TYPE' && error.message.includes('contextExtensions[1]'));
    const cacheOptions = { parsingContext: extensionContext, contextExtensions: [extension], produceCachedData: true };
    const cachedFirst = vm.compileFunction('return inside+outside', [], cacheOptions);
    assert.equal(cachedFirst.cachedDataProduced, true);
    assert(Buffer.isBuffer(cachedFirst.cachedData));
    const cachedSecond = vm.compileFunction('return inside+outside', [], { ...cacheOptions, cachedData: cachedFirst.cachedData });
    assert.equal(cachedSecond.cachedDataRejected, false);
    assert.equal(cachedSecond.cachedDataProduced, true);
    assert(Buffer.isBuffer(cachedSecond.cachedData));
    assert.equal(cachedSecond(), 57);
    const cachedThird = vm.compileFunction('return inside+outside', [], { ...cacheOptions, contextExtensions: [{ inside: 100 }], cachedData: cachedFirst.cachedData });
    assert.equal(cachedThird.cachedDataRejected, false);
    assert.equal(cachedThird(), 107);
    assert.equal(cachedSecond(), 57);
    assert.equal(vm.runInContext('typeof inside', extensionContext), 'undefined');
    const strictSource = '"use strict";globalThis.cacheAnswer=42';
    const strictScript = new vm.Script(strictSource);
    const strictCache = strictScript.createCachedData();
    const strictConsumer = new vm.Script(strictSource, { cachedData: strictCache });
    assert.equal(strictConsumer.cachedDataRejected, false);
    const strictContext = vm.createContext({});
    strictConsumer.runInContext(strictContext);
    assert.equal(strictContext.cacheAnswer, 42);
  `], { encoding: 'utf8', timeout: 10000 })
  assert.equal(reuse.error, undefined)
  assert.equal(reuse.signal, null)
  assert.equal(reuse.status, 0, reuse.stderr)

  const small = vm.createContext({})
  const large = vm.createContext({})
  vm.runInContext('globalThis.payload = new Array(2000).fill(7)', small)
  vm.runInContext('globalThis.payload = new Array(8000).fill(11)', large)
  const result = await vm.measureMemory({ mode: 'detailed', execution: 'eager' })
  bounds(result.total)
  bounds(result.current)
  assert.equal(result.other.length, 2)
  for (const range of result.other) bounds(range)
  const sizes = result.other.map(range => range.jsMemoryEstimate).sort((a, b) => a - b)
  assert(sizes[1] > sizes[0] + 10000, JSON.stringify(result))
  assert(result.other.every(range => range.jsMemoryEstimate < result.total.jsMemoryEstimate))
  assert.equal(small.payload.length, 2000)
  assert.equal(large.payload.length, 8000)

  const collect = () => globalThis.Bun ? Bun.gc(true) : globalThis.gc()
  const pending = vm.measureMemory({ mode: 'detailed' })
  collect()
  assert.equal((await pending).other.length, 2)
  const overlap = [
    vm.measureMemory({ execution: 'eager' }),
    vm.measureMemory({ mode: 'detailed', execution: 'eager' }),
    vm.measureMemory(),
  ]
  collect()
  for (const measurement of await Promise.all(overlap)) bounds(measurement.total)

  const child = spawnSync(process.execPath, ['-e', "require('node:vm').measureMemory(); process.exit(0)"], {
    encoding: 'utf8',
    timeout: 10000,
    env: { ...process.env, BUN_DESTRUCT_VM_ON_EXIT: '1' },
  })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  assert.equal(child.status, 0, child.stderr)
  const worker = new Worker(`
    const { parentPort } = require('node:worker_threads');
    require('node:vm').measureMemory();
    parentPort.on('message', () => {});
    parentPort.postMessage('pending');
  `, { eval: true })
  await new Promise((resolve, reject) => {
    worker.once('message', resolve)
    worker.once('error', reject)
  })
  assert.equal(typeof await worker.terminate(), 'number')
}
main().catch(error => { throw error })
