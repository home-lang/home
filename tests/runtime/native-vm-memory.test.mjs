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

function contextOptionsSemantics() {
  const contextKeys = ['name', 'origin', 'codeGeneration', 'microtaskMode', 'importModuleDynamically']
  const contextDefaults = { name: 'snapshot-realm', origin: 'snapshot-origin', codeGeneration: {}, microtaskMode: undefined, importModuleDynamically: undefined }
  for (const invalid of contextKeys) {
    const reads = []
    const options = {}
    for (const key of contextKeys) {
      Object.defineProperty(options, key, {
        get() { reads.push(key); return key === invalid ? 17 : contextDefaults[key] },
      })
    }
    assert.throws(() => vm.createContext({}, options), {
      code: invalid === 'microtaskMode' ? 'ERR_INVALID_ARG_VALUE' : 'ERR_INVALID_ARG_TYPE',
    })
    assert.deepEqual(reads, contextKeys)
  }
  const originReads = []
  const originGetterError = new Error('origin getter')
  assert.throws(() => vm.createContext({}, {
    get name() { originReads.push('name'); return 17 },
    get origin() { originReads.push('origin'); throw originGetterError },
  }), error => error === originGetterError)
  assert.deepEqual(originReads, ['name', 'origin'])
  for (const kind of ['options', 'codeGeneration']) {
    const operations = []
    const options = new Proxy({}, {
      get(target, key) { operations.push(['get', key]); return Reflect.get(target, key) },
      has(target, key) { operations.push(['has', key]); return Reflect.has(target, key) },
    })
    vm.createContext({}, kind === 'options' ? options : { codeGeneration: options })
    assert.deepEqual(operations, (kind === 'options' ? contextKeys : ['strings', 'wasm']).map(key => ['get', key]))
  }
  for (const value of [[], () => {}, new Proxy([], {}), new Proxy(() => {}, {})]) {
    assert.throws(() => vm.createContext({}, value), { code: 'ERR_INVALID_ARG_TYPE' })
    assert.throws(() => vm.createContext({}, { codeGeneration: value }), { code: 'ERR_INVALID_ARG_TYPE' })
    for (const run of [vm.runInNewContext, (code, context, options) => new vm.Script(code).runInNewContext(context, options)]) {
      assert.throws(() => run('42', {}, { contextCodeGeneration: value }), { code: 'ERR_INVALID_ARG_TYPE' })
    }
  }
  assert.throws(() => vm.createContext({}, {
    codeGeneration: { strings: 17 }, microtaskMode: 17, importModuleDynamically: 17,
  }), error => error.code === 'ERR_INVALID_ARG_TYPE' && error.message.includes('codeGeneration.strings'))
  assert.throws(() => vm.createContext({}, {
    microtaskMode: 17, importModuleDynamically: 17,
  }), { code: 'ERR_INVALID_ARG_VALUE' })
  function contextGetterCollection() {
    const reads = []
    const collect = () => globalThis.Bun ? Bun.gc(true) : globalThis.gc()
    const context = vm.createContext({}, {
      get codeGeneration() {
        return {
          get strings() { reads.push('strings'); collect(); return false },
          get wasm() { reads.push('wasm'); collect(); return true },
        }
      },
      get microtaskMode() { collect(); return undefined },
      get importModuleDynamically() { return () => import('node:fs') },
    })
    assert.deepEqual(reads, ['strings', 'wasm'])
    assert.throws(() => vm.runInContext('eval("42")', context), { name: 'EvalError' })
  }
  contextGetterCollection()
  const scriptReads = []
  assert.equal(new vm.Script('42').runInNewContext({}, {
    get contextName() { scriptReads.push('name'); return 'script-snapshot' },
    get contextOrigin() { scriptReads.push('origin'); return 'script-origin' },
    get microtaskMode() { scriptReads.push('mode'); return 'afterEvaluate' },
    get contextCodeGeneration() {
      scriptReads.push('generation')
      return {
        get strings() { scriptReads.push('strings'); return true },
        get wasm() { scriptReads.push('wasm'); return true },
      }
    },
  }), 42)
  assert.deepEqual(scriptReads, ['name', 'origin', 'mode', 'generation', 'generation', 'generation', 'strings', 'wasm', 'mode', 'mode'])
  for (const finalValue of [17, [], () => {}, null, undefined]) {
    let reads = 0
    const options = {
      get contextCodeGeneration() { return ++reads < 3 ? {} : finalValue },
    }
    if (finalValue === null || finalValue === undefined) {
      assert.throws(() => new vm.Script('42').runInNewContext({}, options), { name: 'TypeError' })
    } else {
      assert.equal(new vm.Script('42').runInNewContext({}, options), 42)
    }
    assert.equal(reads, 3)
  }
  let modeReads = 0
  const snapshotQueue = { value: 0 }
  new vm.Script('Promise.resolve().then(() => value++); void 0').runInNewContext(snapshotQueue, {
    get microtaskMode() { return ++modeReads === 1 ? 'afterEvaluate' : undefined },
  })
  assert.equal(snapshotQueue.value, 1)
  assert.equal(modeReads, 2)
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
}

function scriptOptionsSemantics() {
  const collect = () => globalThis.Bun ? Bun.gc(true) : globalThis.gc()
  for (const key of ['contextName', 'contextOrigin', 'timeout', 'microtaskMode']) {
    const options = { get [key]() { throw new Error('ignored construction field') } }
    assert.equal(new vm.Script('42', options).runInThisContext(), 42)
  }
  const script = new vm.Script('42')
  for (const key of ['filename', 'lineOffset', 'columnOffset', 'cachedData', 'produceCachedData', 'contextName', 'contextOrigin']) {
    const options = { get [key]() { throw new Error('ignored execution field') } }
    assert.equal(script.runInThisContext(options), 42)
    assert.equal(script.runInContext(vm.createContext({}), options), 42)
  }
  const keys = ['filename', 'lineOffset', 'columnOffset', 'cachedData', 'produceCachedData', 'importModuleDynamically']
  const reads = []
  const defaults = { filename: 'option-snapshot.vm', lineOffset: 0, columnOffset: 0, cachedData: undefined, produceCachedData: false, importModuleDynamically: undefined }
  const options = {}
  for (const key of keys) Object.defineProperty(options, key, { get() { reads.push(key); return defaults[key] } })
  assert.equal(new vm.Script('42', options).runInThisContext(), 42)
  assert.deepEqual(reads, keys)
  const marker = new Error('later option getter')
  assert.throws(() => new vm.Script('42', {
    filename: 17, get lineOffset() { throw marker },
  }), error => error === marker)
  assert.throws(() => new vm.Script('42', {
    cachedData: 'bad', produceCachedData: 'bad',
  }), error => error.code === 'ERR_INVALID_ARG_TYPE' && error.message.includes('cachedData'))
  const virtual = new Proxy({}, {
    get(target, key) { return key === 'filename' ? 'virtual-option.vm' : Reflect.get(target, key) },
    has() { throw new Error('unexpected has operation') },
  })
  assert.throws(() => new vm.Script('throw new Error("virtual filename")', virtual).runInThisContext(), error => error.stack.includes('virtual-option.vm'))
  const runtimeReads = []
  assert.equal(script.runInThisContext({
    get timeout() { runtimeReads.push('timeout'); return undefined },
    get displayErrors() { runtimeReads.push('displayErrors'); return true },
    get breakOnSigint() { runtimeReads.push('breakOnSigint'); return false },
  }), 42)
  assert.deepEqual(runtimeReads, ['timeout', 'displayErrors', 'breakOnSigint'])
  assert.throws(() => script.runInThisContext({
    displayErrors: 17, get breakOnSigint() { throw marker },
  }), error => error === marker)
  assert.throws(() => script.runInThisContext({
    timeout: 0, get displayErrors() { throw marker },
  }), { code: 'ERR_OUT_OF_RANGE' })
  assert.equal(script.runInThisContext(new Proxy({}, {
    get(target, key) { return Reflect.get(target, key) },
    has() { throw new Error('unexpected runtime has operation') },
  })), 42)
  for (const value of [[], () => {}, new Proxy([], {}), new Proxy(() => {}, {})]) {
    assert.throws(() => new vm.Script('42', value), { code: 'ERR_INVALID_ARG_TYPE' })
    assert.throws(() => script.runInThisContext(value), { code: 'ERR_INVALID_ARG_TYPE' })
  }
  for (const value of [0, -1, 2 ** 32, 1.5, NaN]) {
    assert.throws(() => script.runInThisContext({ timeout: value }), { code: 'ERR_OUT_OF_RANGE' })
  }
  assert.equal(script.runInThisContext({ timeout: 2 ** 32 - 1 }), 42)
  for (const value of [-0, 0, 2147483647, -2147483648]) {
    assert.equal(new vm.Script('42', { lineOffset: value, columnOffset: value }).runInThisContext(), 42)
  }
  for (const value of [2147483648, -2147483649, 1.5, NaN]) {
    assert.throws(() => new vm.Script('42', { lineOffset: value }), { code: 'ERR_OUT_OF_RANGE' })
  }
  assert.throws(() => new vm.Script('42', { cachedData: new ArrayBuffer(0) }), { code: 'ERR_INVALID_ARG_TYPE' })
  for (const [label, cachedData] of [['buffer', Buffer.alloc(0)], ['view', new Uint8Array(0)], ['dataview', new DataView(new ArrayBuffer(0))]]) {
    const emptyCache = new vm.Script(`17 + 25 /* empty option cache ${label} */`, { cachedData })
    assert.equal(emptyCache.cachedDataRejected, true)
    assert.equal(emptyCache.runInThisContext(), 42)
  }
  assert.equal(new vm.Script('17 + 25 /* omitted option cache */').cachedDataRejected, undefined)
  const producedAfterEmpty = new vm.Script('17 + 25 /* produce after empty option cache */', {
    cachedData: Buffer.alloc(0), produceCachedData: true,
  })
  assert.equal(producedAfterEmpty.cachedDataRejected, true)
  assert.equal(producedAfterEmpty.cachedDataProduced, true)
  assert(Buffer.isBuffer(producedAfterEmpty.cachedData))
  assert(producedAfterEmpty.cachedData.length > 0)
  const collectedCache = new vm.Script('17 + 25 /* option getter GC cache */', {
    get cachedData() { return Buffer.from('invalid-bytecode') },
    get produceCachedData() { collect(); return false },
    get importModuleDynamically() { collect(); return undefined },
  })
  assert.equal(collectedCache.cachedDataRejected, true)
  assert.equal(collectedCache.runInThisContext(), 42)
}

function scriptDisplaySemantics() {
  for (const run of [
    (script, options) => script.runInThisContext(options),
    (script, options) => script.runInContext(vm.createContext({}), options),
    (script, options) => script.runInNewContext({}, options),
  ]) {
    for (const displayErrors of [undefined, true, false]) {
      const source = 'throw new Error("display marker")'
      const script = new vm.Script(source, { filename: 'display-probe.vm' })
      assert.throws(() => run(script, { displayErrors }), error => {
        assert.equal(error.name, 'Error')
        assert.equal(error.message, 'display marker')
        assert.equal(error.stack.startsWith('display-probe.vm:1\n'), displayErrors !== false)
        assert.equal(error.stack.includes(source + '\n'), displayErrors !== false)
        return true
      })
    }
  }
  for (const innerDisplay of [false, true]) {
    for (const outerDisplay of [false, true]) {
      const context = vm.createContext({
        inner() {
          new vm.Script('throw new Error("nested display")', { filename: 'inner-display.vm' }).runInThisContext({ displayErrors: innerDisplay })
        },
      })
      assert.throws(() => new vm.Script('inner()', { filename: 'outer-display.vm' }).runInContext(context, { displayErrors: outerDisplay }), error => {
        assert.equal(error.stack.startsWith('inner-display.vm:1\n'), innerDisplay || outerDisplay)
        assert.equal((error.stack.match(/inner-display\.vm:1\n/g) || []).length, innerDisplay || outerDisplay ? 1 : 0)
        return true
      })
    }
  }
  const marker = new Error('stack getter marker')
  let reads = 0
  Object.defineProperty(marker, 'stack', {
    get() { reads++; throw new Error('stack getter executed') },
  })
  assert.throws(() => new vm.Script('throw marker').runInContext(vm.createContext({ marker }), { displayErrors: false }), error => error === marker)
  assert.equal(reads, 0)
}

async function main() {
  contextOptionsSemantics()
  scriptOptionsSemantics()
  scriptDisplaySemantics()
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
