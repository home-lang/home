import { expect, test } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { replaceModuleLiteral } from './native_module_abi'

const root = path.resolve(import.meta.dir, '..')
const nativeBuild = path.dirname(process.env.HOME_BUN_OBJ_ROOT || '/Users/chris/Code/bun/build/release/obj')
const available = existsSync(path.join(nativeBuild, 'codegen/InternalModuleRegistryConstants.h'))
const nativeTest = available ? test : test.skip
const read = (file: string) => readFileSync(file, 'utf8')
const ownedBuiltinNames = ['NodeUrl', 'NodeWorkerThreads', 'NodeQuerystring', 'NodeAssert', 'NodeAssertStrict', 'NodeEvents', 'NodeAsyncHooks', 'NodeDgram', 'NodeNet', 'NodeTimers', 'NodeTimersPromises', 'InternalAsyncHooks', 'InternalAsyncHooksTick', 'NodePath', 'NodePathPosix', 'NodePathWin32', 'NodeUtil', 'NodeDomain', 'NodePunycode', 'NodeDiagnosticsChannel', 'NodeOS', 'NodeDNS', 'NodeDNSPromises', 'InternalShared', 'InternalErrors', 'InternalValidators', 'InternalUtilInspect', 'InternalUtilColors', 'InternalUtilDeprecate', 'InternalUtilMime', 'InternalPrimordials', 'InternalStreamsAddAbortSignal', 'InternalStreamsCompose', 'InternalStreamsDestroy', 'InternalStreamsDuplex', 'InternalStreamsDuplexify', 'InternalStreamsDuplexpair', 'InternalStreamsEndOfStream', 'InternalStreamsFrom', 'InternalStreamsIterBroadcast', 'InternalStreamsIterClassic', 'InternalStreamsIterConsumers', 'InternalStreamsIterDuplex', 'InternalStreamsIterFrom', 'InternalStreamsIterPull', 'InternalStreamsIterPush', 'InternalStreamsIterRingbuffer', 'InternalStreamsIterShare', 'InternalStreamsIterTransform', 'InternalStreamsIterTypes', 'InternalStreamsIterUtils', 'InternalStreamsLazyTransform', 'InternalStreamsLegacy', 'InternalStreamsNativeReadable', 'InternalStreamsOperators', 'InternalStreamsPassthrough', 'InternalStreamsPipeline', 'InternalStreamsReadable', 'InternalStreamsState', 'InternalStreamsTransform', 'InternalStreamsUtils', 'InternalStreamsWritable', 'InternalWebstreamsAdapters', 'NodeStreamConsumers', 'NodeStreamIter', 'NodeStreamPromises', 'NodeStream', 'NodeStreamWeb', 'NodeFS', 'NodeFSPromises', 'NodeChildProcess', 'NodeCluster', 'InternalFSBinding', 'InternalFSCpSync', 'InternalFSCp', 'InternalFSGlob', 'InternalFSStreams', 'InternalFSWatch', 'InternalFSWatchfile', 'NodeTest', 'NodeCrypto', 'NodeZlib', 'NodeZlibIter', 'InternalPromisify', 'NodeStreamDuplex', 'NodeStreamPassthrough', 'NodeStreamReadable', 'NodeStreamTransform', 'NodeStreamWrap', 'NodeStreamWritable']
const units = ['UnifiedSource-src_jsc_bindings-1.cpp', 'UnifiedSource-src_jsc_bindings_webcore-3.cpp', 'UnifiedSource-src_jsc_bindings_webcore-4.cpp', 'UnifiedSource-src_jsc_bindings_webcore-5.cpp', 'UnifiedSource-src_jsc_bindings-0.cpp', 'UnifiedSource-src_jsc_bindings_webcore-2.cpp', 'UnifiedSource-src_jsc_bindings_webcore-1.cpp', 'UnifiedSource-src_jsc_bindings_webcore-0.cpp', 'UnifiedSource-src_jsc_bindings-4.cpp', 'UnifiedSource-src_jsc_bindings-3.cpp', 'UnifiedSource-src_jsc_bindings-5.cpp', 'UnifiedSource-src_jsc_modules-0.cpp', 'UnifiedSource-src_jsc_bindings-2.cpp']

function createNativeFixture(temporary: string) {
  const codegen = path.join(temporary, 'codegen')
  const webcore = path.join(temporary, 'webcore')
  mkdirSync(codegen)
  mkdirSync(path.join(temporary, 'js'))
  mkdirSync(webcore)
  mkdirSync(path.join(temporary, 'unified'))
  for (const file of ['InternalModuleRegistry+enum.h', 'GeneratedJS2Native.h', 'ErrorCode+List.h', 'InternalModuleRegistryConstants.h', 'NativeModuleImpl.h', 'ZigGeneratedClasses.cpp']) {
    writeFileSync(path.join(codegen, file), read(path.join(nativeBuild, 'codegen', file)))
  }
  writeFileSync(
    path.join(temporary, 'js/internal-for-testing.js'),
    read(path.join(nativeBuild, 'js/internal-for-testing.js')),
  )
  for (const name of units) {
    const unifiedPath = path.join(nativeBuild, 'unified', name)
    // Relative includes belong to the original unified directory, not this
    // temporary build root. Isolate just the selected sources and class headers
    // so ABI-drift tests never modify the external tree.
    const unified = read(unifiedPath).replace(/^#include "([^"]+)"$/gm, (_, relative) => {
      const externalSource = path.resolve(path.dirname(unifiedPath), relative)
      const basename = path.basename(relative)
      if (['MessagePort.cpp', 'MessagePortPipe.cpp', 'Worker.cpp', 'BunWorkerGlobalScope.cpp', 'JSMessagePort.cpp', 'JSWorker.cpp', 'BunAnalyzeTranspiledModule.cpp', 'JSAbortSignalCustom.cpp', 'BroadcastChannel.cpp', 'BunBroadcastChannelRegistry.cpp', 'JSBroadcastChannel.cpp', 'MessageEvent.cpp', 'JSMessageEvent.cpp', 'ScriptExecutionContext.cpp', 'NodeAsyncHooks.cpp', 'WebSocket.cpp', 'JSWebSocket.cpp', 'AsyncContextFrame.cpp', 'IPC.cpp', 'Path.cpp', 'NodeValidator.cpp', 'stringWidth.cpp', 'NodeUtilTypesModule.cpp', 'JSMIMEParams.cpp', 'sliceAnsi.cpp', 'stripANSI.cpp', 'wrapAnsi.cpp', 'napi_finalizer.cpp', 'NodeModuleModule.cpp', 'ReadableStream.cpp', 'JSReadableStream.cpp', 'JSStringDecoder.cpp'].includes(basename)) {
        const header = basename === 'JSAbortSignalCustom.cpp' ? 'AbortSignal.h' : basename.replace(/\.cpp$/, '.h')
        writeFileSync(path.join(webcore, basename), readFileSync(externalSource))
        if (basename !== 'IPC.cpp') writeFileSync(path.join(webcore, header), readFileSync(path.join(path.dirname(externalSource), header)))
        return `#include ${JSON.stringify(path.join(webcore, basename))}`
      }
      return `#include ${JSON.stringify(externalSource)}`
    })
    writeFileSync(path.join(temporary, 'unified', name), unified)
  }
  return { codegen, webcore }
}

function generate(nativeRoot: string, output: string) {
  return Bun.spawnSync([process.execPath, path.join(import.meta.dir, 'bundle-native-modules.ts'), nativeRoot, output], {
    cwd: root, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe', timeout: 15000,
  })
}

nativeTest('generates owned builtins and the stream adapter while preserving other literals', () => {
  const cache = path.join(root, '.zig-cache/tmp')
  mkdirSync(cache, { recursive: true })
  const output = mkdtempSync(path.join(cache, 'home-builtin-test-'))
  try {
    const result = Bun.spawnSync([process.execPath, path.join(import.meta.dir, 'bundle-native-modules.ts'), nativeBuild, output], {
      cwd: root,
      stdin: 'ignore', stdout: 'pipe', stderr: 'pipe',
      timeout: 15000,
    })
    expect(result.exitCode, result.stderr.toString()).toBe(0)
    for (const name of ownedBuiltinNames) {
      const source = read(path.join(output, name + '.js'))
      expect(source).not.toMatch(/^\s*(?:export|import)\s/m)
      if (name === 'NodeUrl' || name === 'NodeWorkerThreads') expect(source).not.toContain('__commonJS')
      expect(source).not.toContain('import.meta.require(')
      // Check complete function grammar without executing native intrinsics.
      expect(() => new Function(`return ${source.replace(/@([A-Za-z_])/g, '__intrinsic__$1')}`)).not.toThrow()
    }
    expect(read(path.join(output, 'NativeModuleImpl.h'))).toContain('#include \"NodeBufferModule.h\"')
    expect(readFileSync(path.join(output, 'NodeStringDecoderModule.h'))).toEqual(readFileSync(path.join(root, 'packages/runtime/upstream/src/jsc/modules/NodeStringDecoderModule.h')))
    expect(readFileSync(path.join(output, 'NodeBufferModule.h'))).toEqual(readFileSync(path.join(root, 'packages/runtime/upstream/src/jsc/modules/NodeBufferModule.h')))
    const internalForTesting = read(path.join(output, 'InternalForTesting.js'))
    expect(internalForTesting).toContain('class HomeJSStreamSocket extends HomeDuplex')
    expect(internalForTesting).toContain('class HomeWriteWrap extends HomeStreamRequest')
    expect(internalForTesting).toContain('streamBaseState: new Int32Array(4)')
    expect(internalForTesting).toContain('"internal/js_stream_socket": HomeJSStreamSocket')
    expect(internalForTesting).toContain('"internal/test/binding": { internalBinding: homeInternalTestBinding }')
    expect(internalForTesting).toContain('@lazy(99)')
    const external = read(path.join(nativeBuild, 'codegen/InternalModuleRegistryConstants.h'))
    const generated = read(path.join(output, 'InternalModuleRegistryConstants.h'))
    expect(generated).not.toBe(external)
    const stripOwned = (header: string) => [...ownedBuiltinNames, 'InternalForTesting']
      .reduce((value, name) => replaceModuleLiteral(value, name, 'OWNED_' + name), header)
    expect(stripOwned(generated)).toBe(stripOwned(external))
    expect(read(path.join(output, 'HomeInternalModuleRegistry.cpp')))
      .toContain('#include "InternalModuleRegistry.cpp"')
    const ipc = path.join(root, 'packages/runtime/upstream/src/jsc/bindings/IPC.cpp')
    expect(read(path.join(output, 'HomeInternalModuleRegistry.cpp'))).toContain('#include \"IPC.cpp\"')
    expect(read(path.join(output, 'IPC.cpp'))).toBe(`#line 1 ${JSON.stringify(ipc)}\n${read(ipc)}`)
    const materializer = path.join(root, 'packages/runtime/src/native/H2HeadersMaterializer.cpp')
    expect(read(path.join(output, 'HomeInternalModuleRegistry.cpp')))
      .toContain('#include "H2HeadersMaterializer.cpp"')
    expect(read(path.join(output, 'H2HeadersMaterializer.cpp')))
      .toBe(`#line 1 ${JSON.stringify(materializer)}\n${read(materializer)}`)
    for (const [basename, unitName, unitOutput = 'Home' + basename] of [['JSStringDecoder.cpp', units[12]], ['MessagePort.cpp', units[1]], ['MessagePortPipe.cpp', units[2]], ['Worker.cpp', units[3]], ['BunWorkerGlobalScope.cpp', units[4]], ['JSMessagePort.cpp', units[5]], ['JSAbortSignalCustom.cpp', units[6]], ['BroadcastChannel.cpp', units[7]], ['ScriptExecutionContext.cpp', units[8]], ['NodeAsyncHooks.cpp', units[9]], ['stringWidth.cpp', units[10], 'HomeStringWidth.cpp'], ['NodeUtilTypesModule.cpp', units[11]]]) {
      const generatedUnit = read(path.join(output, unitOutput))
      const externalUnit = read(path.join(nativeBuild, 'unified', unitName))
      const ownedNames = basename === 'MessagePort.cpp' ? [basename, 'JSWorker.cpp', 'MessageEvent.cpp', 'JSWebSocket.cpp', 'JSReadableStream.cpp']
        : basename === 'BunWorkerGlobalScope.cpp' ? [basename, 'BunAnalyzeTranspiledModule.cpp', 'AsyncContextFrame.cpp']
          : basename === 'JSAbortSignalCustom.cpp' ? [basename, 'JSBroadcastChannel.cpp']
            : basename === 'JSMessagePort.cpp' ? [basename, 'JSMessageEvent.cpp', 'JSMIMEParams.cpp']
              : basename === 'Worker.cpp' ? [basename, 'WebSocket.cpp']
                : basename === 'BroadcastChannel.cpp' ? [basename, 'BunBroadcastChannelRegistry.cpp'] : basename === 'NodeAsyncHooks.cpp' ? [basename, 'Path.cpp', 'NodeValidator.cpp'] : basename === 'stringWidth.cpp' ? [basename, 'sliceAnsi.cpp', 'stripANSI.cpp', 'wrapAnsi.cpp', 'napi_finalizer.cpp'] : basename === 'NodeUtilTypesModule.cpp' ? [basename, 'NodeModuleModule.cpp'] : basename === 'MessagePortPipe.cpp' ? [basename, 'ReadableStream.cpp'] : [basename]
      const expectedUnit = externalUnit.replace(/^#include "([^"]+)"$/gm, (_, relative) => ownedNames.includes(path.basename(relative))
        ? `#include ${JSON.stringify(path.basename(relative))}`
        : `#include ${JSON.stringify(path.resolve(nativeBuild, 'unified', relative))}`)
      expect(generatedUnit).toBe(expectedUnit)
      const includes = [...generatedUnit.matchAll(/^#include "([^"]+)"$/gm)].map(match => match[1])
      expect(includes.filter(include => include === basename)).toHaveLength(1)
      const externalIncludes = [...externalUnit.matchAll(/^#include "([^"]+)"$/gm)]
      expect(includes.filter(include => path.isAbsolute(include))).toHaveLength(externalIncludes.length - ownedNames.length)
      for (const name of ownedNames) {
        const homeSource = path.join(root, 'packages/runtime/upstream/src/jsc', ['NodeUtilTypesModule.cpp', 'NodeModuleModule.cpp'].includes(name) ? 'modules' : 'bindings', ['BunWorkerGlobalScope.cpp', 'BunAnalyzeTranspiledModule.cpp', 'ScriptExecutionContext.cpp', 'NodeAsyncHooks.cpp', 'AsyncContextFrame.cpp', 'Path.cpp', 'NodeValidator.cpp', 'stringWidth.cpp', 'NodeUtilTypesModule.cpp', 'sliceAnsi.cpp', 'stripANSI.cpp', 'wrapAnsi.cpp', 'napi_finalizer.cpp', 'NodeModuleModule.cpp', 'JSStringDecoder.cpp'].includes(name) ? '' : 'webcore', name)
        expect(read(path.join(output, name))).toBe(`#line 1 ${JSON.stringify(homeSource)}\n${read(homeSource)}`)
      }
    }
    for (const privateHeader of ['HomeMessagePortLifecycle.h', 'HomeWorkerSnapshots.h', 'HomeWebSocketAsyncContext.h']) {
      expect(readFileSync(path.join(output, privateHeader)))
        .toEqual(readFileSync(path.join(root, 'packages/runtime/upstream/src/jsc/bindings/webcore', privateHeader)))
    }
    for (const privateHeader of ['ANSIHelpers.h', 'stringWidthTables.h']) {
      expect(readFileSync(path.join(output, privateHeader))).toEqual(readFileSync(path.join(root, 'packages/runtime/upstream/src/jsc/bindings', privateHeader)))
    }
    expect(existsSync(path.join(output, 'MessagePort.h'))).toBe(false)
    expect(existsSync(path.join(output, 'MessagePortPipe.h'))).toBe(false)
    expect(existsSync(path.join(output, 'Worker.h'))).toBe(false)
    expect(read(path.join(output, 'MessagePort.cpp'))).toContain('vm.propertyNames->message, value')
  } finally {
    rmSync(output, { recursive: true })
  }
}, 45000)

nativeTest('rejects native class identity drift before producing artifacts', () => {
  const cache = path.join(root, '.zig-cache/tmp')
  mkdirSync(cache, { recursive: true })
  const temporary = mkdtempSync(path.join(cache, 'home-class-abi-test-'))
  try {
    const { codegen } = createNativeFixture(temporary)
    const source = path.join(codegen, 'ZigGeneratedClasses.cpp')
    const original = read(source)
    for (const changed of [
      original.replace('case 0: return JSValue::encode(jsBoolean(dynamicDowncast<WebCore::JSBlob>', 'case 7: return JSValue::encode(jsBoolean(dynamicDowncast<WebCore::JSBlob>'),
      original.replace('dynamicDowncast<WebCore::JSReadableStream>(cell)', 'dynamicDowncast<WebCore::JSWritableStream>(cell)'),
      original.replace('auto value = callFrame->argument(1);', 'auto value = callFrame->argument(0);'),
    ]) {
      expect(changed).not.toBe(original)
      writeFileSync(source, changed)
      const output = path.join(temporary, 'output')
      const result = generate(temporary, output)
      expect(result.exitCode, result.stderr.toString()).toBe(1)
      expect(result.stderr.toString()).toContain('Linked native class identity ABI mismatch')
      expect(existsSync(output)).toBe(false)
    }
  } finally {
    rmSync(temporary, { recursive: true })
  }
}, 45000)

nativeTest('rejects error and native-wrapper ABI drift before producing linkable artifacts', () => {
  const cache = path.join(root, '.zig-cache/tmp')
  mkdirSync(cache, { recursive: true })
  const temporary = mkdtempSync(path.join(cache, 'home-builtin-abi-test-'))
  try {
    const { codegen } = createNativeFixture(temporary)
    const baseline = Bun.spawnSync([process.execPath, path.join(import.meta.dir, 'bundle-native-modules.ts'), temporary, path.join(temporary, 'baseline')], {
      cwd: root, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe', timeout: 15000,
    })
    expect(baseline.exitCode, baseline.stderr.toString()).toBe(0)
    const errorHeader = path.join(codegen, 'ErrorCode+List.h')
    const original = read(errorHeader)
    expect(original).toContain('ABORT_ERR = 0,')
    writeFileSync(errorHeader, original.replace('ABORT_ERR = 0,', 'ABORT_ERR = 99,'))
    const output = path.join(temporary, 'output')
    const result = Bun.spawnSync([process.execPath, path.join(import.meta.dir, 'bundle-native-modules.ts'), temporary, output], {
      cwd: root,
      stdin: 'ignore', stdout: 'pipe', stderr: 'pipe',
      timeout: 15000,
    })
    expect(result.exitCode).not.toBe(0)
    expect(existsSync(output)).toBe(false)
    writeFileSync(errorHeader, original)
    const wrapperHeader = path.join(codegen, 'GeneratedJS2Native.h')
    const wrappers = read(wrapperHeader)
    const signature = 'return createNodeWorkerThreadsBinding(global);'
    expect(wrappers).toContain(signature)
    writeFileSync(wrapperHeader, wrappers.replace(signature, 'return missingNodeWorkerThreadsBinding(global);'))
    const wrapperOutput = path.join(temporary, 'wrapper-output')
    const mismatch = Bun.spawnSync([process.execPath, path.join(import.meta.dir, 'bundle-native-modules.ts'), temporary, wrapperOutput], {
      cwd: root, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe', timeout: 15000,
    })
    expect(mismatch.signalCode).toBeUndefined()
    expect(mismatch.exitCode).toBe(1)
    expect(existsSync(wrapperOutput)).toBe(false)
    for (const [symbol, length] of [['jsSetAsyncHooksEnabled', 1], ['jsCleanupLater', 0]] as const) {
      const signature = `globalObject, ${length}, "${symbol}"_s, ${symbol},`
      expect(wrappers).toContain(signature)
      writeFileSync(wrapperHeader, wrappers.replace(signature, `globalObject, ${length + 1}, "${symbol}"_s, ${symbol},`))
      const output = path.join(temporary, symbol + '-output')
      const result = generate(temporary, output)
      expect(result.signalCode).toBeUndefined()
      expect(result.exitCode).toBe(1)
      expect(result.stderr.toString()).toContain(`Linked native wrapper signature mismatch: ${symbol}`)
      expect(existsSync(output)).toBe(false)
    }
  } finally {
    rmSync(temporary, { recursive: true })
  }
}, 45000)

nativeTest.each(['NodeBufferModule.h', 'NodeStringDecoderModule.h'])('rejects invalid native factory include: %s', basename => {
  const cache = path.join(root, '.zig-cache/tmp')
  mkdirSync(cache, { recursive: true })
  const temporary = mkdtempSync(path.join(cache, 'home-factory-ownership-test-'))
  try {
    const { codegen } = createNativeFixture(temporary)
    const header = path.join(codegen, 'NativeModuleImpl.h')
    const original = read(header)
    const includes = original.split('\n').filter(line => line.startsWith('#include ') && line.includes(basename))
    expect(includes).toHaveLength(1)
    for (const [kind, invalid] of [['missing', original.replace(includes[0], '')], ['duplicate', original + includes[0] + '\n']]) {
      writeFileSync(header, invalid)
      const output = path.join(temporary, kind + '-output')
      const result = generate(temporary, output)
      expect(result.exitCode).toBe(1)
      expect(result.stderr.toString()).toContain(`Native module factory header must contain exactly one ${basename}`)
      expect(existsSync(output)).toBe(false)
    }
  } finally {
    rmSync(temporary, { recursive: true })
  }
}, 20000)

// Each owned ABI has its own deadline, so host pressure cannot exhaust one
// aggregate timeout halfway through the independent rejection contracts.
nativeTest.each(['MessagePort.h', 'MessagePortPipe.h', 'Worker.h', 'BunWorkerGlobalScope.h', 'JSMessagePort.h', 'JSWorker.h', 'BunAnalyzeTranspiledModule.h', 'AbortSignal.h', 'BroadcastChannel.h', 'BunBroadcastChannelRegistry.h', 'JSBroadcastChannel.h', 'MessageEvent.h', 'JSMessageEvent.h', 'ScriptExecutionContext.h', 'NodeAsyncHooks.h', 'WebSocket.h', 'JSWebSocket.h', 'AsyncContextFrame.h', 'Path.h', 'NodeValidator.h', 'stringWidth.h', 'NodeUtilTypesModule.h', 'JSMIMEParams.h', 'sliceAnsi.h', 'stripANSI.h', 'wrapAnsi.h', 'napi_finalizer.h', 'NodeModuleModule.h', 'ReadableStream.h', 'JSReadableStream.h', 'JSStringDecoder.h'])('rejects owned native class-header drift: %s', header => {
  const cache = path.join(root, '.zig-cache/tmp')
  mkdirSync(cache, { recursive: true })
  const temporary = mkdtempSync(path.join(cache, 'home-port-header-test-'))
  try {
    const { webcore } = createNativeFixture(temporary)
    const headerPath = path.join(webcore, header)
    writeFileSync(headerPath, Buffer.concat([readFileSync(headerPath), Buffer.from('\n// ABI drift fixture\n')]))
    const output = path.join(temporary, 'output')
    const result = generate(temporary, output)
    expect(result.signalCode).toBeUndefined()
    expect(result.exitCode).toBe(1)
    expect(result.stderr.toString()).toContain(header)
    expect(existsSync(output)).toBe(false)
  } finally {
    rmSync(temporary, { recursive: true })
  }
}, 20000)

nativeTest.each([['MessagePortPipe.cpp', units[2]], ['Worker.cpp', units[3]], ['JSWorker.cpp', units[1]], ['BunAnalyzeTranspiledModule.cpp', units[4]], ['JSAbortSignalCustom.cpp', units[6]], ['BroadcastChannel.cpp', units[7]], ['BunBroadcastChannelRegistry.cpp', units[7]], ['JSBroadcastChannel.cpp', units[6]], ['MessageEvent.cpp', units[1]], ['JSMessageEvent.cpp', units[5]], ['ScriptExecutionContext.cpp', units[8]], ['NodeAsyncHooks.cpp', units[9]], ['WebSocket.cpp', units[3]], ['JSWebSocket.cpp', units[1]], ['AsyncContextFrame.cpp', units[4]], ['IPC.cpp', units[0]], ['Path.cpp', units[9]], ['NodeValidator.cpp', units[9]], ['stringWidth.cpp', units[10]], ['NodeUtilTypesModule.cpp', units[11]], ['JSMIMEParams.cpp', units[5]], ['sliceAnsi.cpp', units[10]], ['stripANSI.cpp', units[10]], ['wrapAnsi.cpp', units[10]], ['napi_finalizer.cpp', units[10]], ['NodeModuleModule.cpp', units[11]], ['ReadableStream.cpp', units[2]], ['JSReadableStream.cpp', units[1]], ['JSStringDecoder.cpp', units[12]]])('rejects invalid native ownership: %s', (basename, unitName) => {
  const cache = path.join(root, '.zig-cache/tmp')
  mkdirSync(cache, { recursive: true })
  const temporary = mkdtempSync(path.join(cache, 'home-port-ownership-test-'))
  try {
    const { webcore } = createNativeFixture(temporary)
    const unit = path.join(temporary, 'unified', unitName)
    const original = read(unit)
    const ownedInclude = `#include ${JSON.stringify(path.join(webcore, basename))}`
    expect(original).toContain(ownedInclude)
    for (const [kind, invalid] of [['missing', original.replace(ownedInclude, '')], ['duplicate', original + ownedInclude + '\n']]) {
      writeFileSync(unit, invalid)
      const output = path.join(temporary, kind + '-output')
      const result = generate(temporary, output)
      expect(result.signalCode).toBeUndefined()
      expect(result.exitCode).toBe(1)
      expect(result.stderr.toString()).toContain(`Native unified source must contain exactly one ${basename}`)
      expect(existsSync(output)).toBe(false)
    }
  } finally {
    rmSync(temporary, { recursive: true })
  }
}, 45000)
