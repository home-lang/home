import { mkdirSync, readFileSync, writeFileSync, writeSync } from 'node:fs'
import path from 'node:path'
import { lowerNamedBuiltinExports } from './builtin_exports'
import { builtinModules } from 'node:module'
import { sliceSourceCode } from '../packages/runtime/upstream/src/codegen/builtin-parser'
import { createAssertClientJS } from '../packages/runtime/upstream/src/codegen/client-js'
import { setNativeCallResolver } from '../packages/runtime/upstream/src/codegen/generate-js2native'
import { declareASCIILiteral, checkAscii } from '../packages/runtime/upstream/src/codegen/helpers'
import { createInternalModuleRegistry } from '../packages/runtime/upstream/src/codegen/internal-module-registry-scanner'
import { define } from '../packages/runtime/upstream/src/codegen/replacements'
import NodeErrors from '../packages/runtime/upstream/src/jsc/bindings/ErrorCode'
import nativeClasses from '../packages/runtime/upstream/src/jsc/bindings/js_classes'
import { assertClassHeaderAbi, assertNativeClassIds, enumValues, moduleEnum, nativeFunctionId, replaceModuleLiteral, requiredId } from './native_module_abi'

async function main() {
  const [externalBuildArg, outputArg] = process.argv.slice(2)
  if (!externalBuildArg || !outputArg) throw new Error('Usage: bundle-native-modules.ts <native-build> <output-directory>')
  const externalBuild = path.resolve(externalBuildArg)
  const output = path.resolve(outputArg)
  const homeSource = path.resolve(import.meta.dir, '../packages/runtime/upstream/src')
  const generated = path.join(externalBuild, 'codegen')
  const read = (file: string) => readFileSync(file, 'utf8')
  const abi = enumValues(read(path.join(generated, 'InternalModuleRegistry+enum.h')))
  const dispatch = read(path.join(generated, 'GeneratedJS2Native.h'))
  assertNativeClassIds(read(path.join(generated, 'ZigGeneratedClasses.cpp')), nativeClasses)
  const errors = enumValues(read(path.join(generated, 'ErrorCode+List.h')))
  let errorIndex = 0
  for (const [code, , , ...constructors] of NodeErrors) {
    if (requiredId(errors, code) !== errorIndex++) throw new Error(`Error ABI mismatch: ${code}`)
    for (const constructor of constructors) {
      if (constructor && requiredId(errors, `${code}_${constructor.name}`) !== errorIndex++) {
        throw new Error(`Error ABI mismatch: ${code}_${constructor.name}`)
      }
    }
  }
  setNativeCallResolver((type, filename, symbol, length) => nativeFunctionId(dispatch, type, filename, symbol, length))

  const externalNativeModules = read(path.join(generated, 'NativeModuleImpl.h'))
  const moduleUnityPath = path.join(externalBuild, 'unified/UnifiedSource-src_jsc_modules-0.cpp')
  const moduleRoots = [...read(moduleUnityPath).matchAll(/^#include "([^"]*NodeModuleModule\.cpp)"$/gm)]
  if (moduleRoots.length !== 1) throw new Error('Native unified source must contain exactly one NodeModuleModule.cpp')
  const nativeHeadersRoot = path.dirname(path.resolve(path.dirname(moduleUnityPath), moduleRoots[0][1]))
  let bufferHeaderCount = 0
  let stringDecoderHeaderCount = 0
  const nativeModuleImpl = externalNativeModules.replace(/^#include "([^"]+)"$/gm, (_, relative) => {
    const name = path.basename(relative)
    if (name === 'NodeStringDecoderModule.h') { stringDecoderHeaderCount++; return '#include "NodeStringDecoderModule.h"' }
    if (name === 'NodeBufferModule.h') { bufferHeaderCount++; return '#include "NodeBufferModule.h"' }
    return `#include ${JSON.stringify(path.join(nativeHeadersRoot, name))}`
  })
  if (bufferHeaderCount !== 1) throw new Error('Native module factory header must contain exactly one NodeBufferModule.h')
  if (stringDecoderHeaderCount !== 1) throw new Error('Native module factory header must contain exactly one NodeStringDecoderModule.h')
  const stringDecoderModuleHeader = readFileSync(path.join(homeSource, 'jsc/modules/NodeStringDecoderModule.h'))
  const bufferModuleHeader = readFileSync(path.join(homeSource, 'jsc/modules/NodeBufferModule.h'))

  const registry = createInternalModuleRegistry(path.join(homeSource, 'js'))
  const requireTransformer = (specifier: string, from: string) => {
    const transformed = registry.requireTransformer(specifier, from)
    // Resolve via the Home source tree, then map its identity to the linked ABI.
    // Home's incomplete mirror does not necessarily have the same numeric IDs.
    const match = transformed.match(/getInternalField\(__intrinsic__internalModuleRegistry, (\d+)\/\*/)
    if (!match) throw new Error(`Cannot resolve builtin identity: ${specifier}`)
    const localId = Number(match[1])
    const id = requiredId(abi, moduleEnum(registry.moduleList[localId]))
    return `(__intrinsic__getInternalField(__intrinsic__internalModuleRegistry, ${id}) || __intrinsic__createInternalModuleById(${id}))`
  }
  globalThis.requireTransformer = requireTransformer

  // This is an explicit ownership manifest, not an assertion that all of the
  // mirrored builtins have been ported. Other literal bytes stay unchanged.
  const ownedModules = ['node/url.ts', 'node/worker_threads.ts', 'node/querystring.ts', 'node/assert.ts', 'node/assert.strict.ts', 'node/events.ts', 'node/async_hooks.ts', 'node/dgram.ts', 'node/net.ts', 'node/timers.ts', 'node/timers.promises.ts', 'internal/async_hooks.ts', 'internal/async_hooks_tick.ts', 'node/path.ts', 'node/path.posix.ts', 'node/path.win32.ts', 'node/util.ts', 'node/domain.ts', 'node/punycode.ts', 'node/diagnostics_channel.ts', 'node/os.ts', 'node/dns.ts', 'node/dns.promises.ts', 'internal/shared.ts', 'internal/errors.ts', 'internal/validators.ts', 'internal/util/inspect.js', 'internal/util/colors.ts', 'internal/util/deprecate.ts', 'internal/util/mime.ts', 'internal/primordials.js', 'internal/streams/add-abort-signal.ts', 'internal/streams/compose.ts', 'internal/streams/destroy.ts', 'internal/streams/duplex.ts', 'internal/streams/duplexify.ts', 'internal/streams/duplexpair.ts', 'internal/streams/end-of-stream.ts', 'internal/streams/from.ts', 'internal/streams/iter/broadcast.ts', 'internal/streams/iter/classic.ts', 'internal/streams/iter/consumers.ts', 'internal/streams/iter/duplex.ts', 'internal/streams/iter/from.ts', 'internal/streams/iter/pull.ts', 'internal/streams/iter/push.ts', 'internal/streams/iter/ringbuffer.ts', 'internal/streams/iter/share.ts', 'internal/streams/iter/transform.ts', 'internal/streams/iter/types.ts', 'internal/streams/iter/utils.ts', 'internal/streams/lazy_transform.ts', 'internal/streams/legacy.ts', 'internal/streams/native-readable.ts', 'internal/streams/operators.ts', 'internal/streams/passthrough.ts', 'internal/streams/pipeline.ts', 'internal/streams/readable.ts', 'internal/streams/state.ts', 'internal/streams/transform.ts', 'internal/streams/utils.ts', 'internal/streams/writable.ts', 'internal/webstreams_adapters.ts', 'node/stream.consumers.ts', 'node/stream.iter.ts', 'node/stream.promises.ts', 'node/stream.ts', 'node/stream.web.ts', 'node/fs.ts', 'node/fs.promises.ts', 'node/child_process.ts', 'node/cluster.ts', 'internal/fs/binding.ts', 'internal/fs/cp-sync.ts', 'internal/fs/cp.ts', 'internal/fs/glob.ts', 'internal/fs/streams.ts', 'internal/fs/watch.ts', 'internal/fs/watchfile.ts', 'node/test.ts', 'node/crypto.ts', 'node/zlib.ts', 'node/zlib.iter.ts', 'internal/promisify.ts', 'node/_stream_duplex.ts', 'node/_stream_passthrough.ts', 'node/_stream_readable.ts', 'node/_stream_transform.ts', 'node/_stream_wrap.ts', 'node/_stream_writable.ts', 'node/http.ts', 'node/https.ts', 'node/_http_agent.ts', 'node/_http_client.ts', 'node/_http_common.ts', 'node/_http_incoming.ts', 'node/_http_outgoing.ts', 'node/_http_server.ts', 'node/tls.ts', 'node/_tls_common.ts', 'node/http2.ts', 'node/_http2_upgrade.ts', 'internal/http.ts', 'internal/url.ts', 'internal/net/isIP.ts', 'internal/timers.ts', 'internal/freelist.ts', 'internal/http/FakeSocket.ts', 'internal/stream.ts', 'internal/cluster/isPrimary.ts', 'internal/tls.ts', 'internal/stream.promises.ts']
  let constants = read(path.join(generated, 'InternalModuleRegistryConstants.h'))
  // Validate every owned module against the linked ABI before starting bundler
  // workers or writing output. A late module mismatch must not leave a partial
  // set of generated native contracts behind.
  const inputs = ownedModules.map(module => {
    const name = moduleEnum(module)
    requiredId(abi, name)
    const source = read(path.join(homeSource, 'js', module))
    const scanned = new Bun.Transpiler({ loader: 'ts' }).scan(source)
    if (scanned.imports.some(item => item.kind === 'import-statement') || scanned.exports.length === 0 || (scanned.exports.includes('default') && scanned.exports.length !== 1)) {
      throw new Error(`Incremental builtin must use require and either default or named exports: ${module}`)
    }
    const processed = sliceSourceCode(`{${source}`, true, specifier => requireTransformer(specifier, module))
    const input = `var $;\n${processed.result.slice(1).trim().replaceAll('__intrinsic__exports', '$')}\n;$$EXPORT$$($).$$EXPORT_END$$;\n`
    if (/__intrinsic__inherits[A-Za-z_]/.test(input)) throw new Error(`Unknown native class identity in ${module}`)
    return { module, name, input, namedExports: scanned.exports.includes('default') ? null : scanned.exports }
  })
  // Preflight native ownership and ABI layout before creating any output.
  // A unified object can contain several owned sources; replace all of them
  // together and leave every other include on its external ABI-matched source.
  const privateHeaders = ['HomeMessagePortLifecycle.h', 'HomeWorkerSnapshots.h', 'HomeWebSocketAsyncContext.h'].map(name => ({
    name, bytes: readFileSync(path.join(homeSource, 'jsc/bindings/webcore', name)),
  }))
  privateHeaders.push(...['ANSIHelpers.h', 'stringWidthTables.h'].map(name => ({
    name, bytes: readFileSync(path.join(homeSource, 'jsc/bindings', name)),
  })))
  const nativeUnits = ([
    [[['jsc/bindings/JSStringDecoder.cpp', 'JSStringDecoder.h']], 'UnifiedSource-src_jsc_bindings-2.cpp', 'HomeJSStringDecoder.cpp'],
    [[['jsc/bindings/webcore/BroadcastChannel.cpp', 'BroadcastChannel.h'], ['jsc/bindings/webcore/BunBroadcastChannelRegistry.cpp', 'BunBroadcastChannelRegistry.h']], 'UnifiedSource-src_jsc_bindings_webcore-0.cpp', 'HomeBroadcastChannel.cpp'],
    [[['jsc/bindings/webcore/JSAbortSignalCustom.cpp', 'AbortSignal.h'], ['jsc/bindings/webcore/JSBroadcastChannel.cpp', 'JSBroadcastChannel.h']], 'UnifiedSource-src_jsc_bindings_webcore-1.cpp', 'HomeJSAbortSignalCustom.cpp'],
    [[['jsc/bindings/ErrorCode.cpp', null], ['jsc/bindings/InternalModuleRegistry.cpp', null], ['jsc/bindings/EventLoopTaskNoContext.cpp', null], ['jsc/bindings/IPC.cpp', null], ['../../src/native/H2HeadersMaterializer.cpp', null]], 'UnifiedSource-src_jsc_bindings-1.cpp', 'HomeInternalModuleRegistry.cpp'],
    [[['jsc/bindings/NodeAsyncHooks.cpp', 'NodeAsyncHooks.h'], ['jsc/bindings/Path.cpp', 'Path.h'], ['jsc/bindings/NodeValidator.cpp', 'NodeValidator.h'], ['jsc/bindings/NodeHTTP.cpp', 'NodeHTTP.h'], ['jsc/bindings/NodeTLS.cpp', 'NodeTLS.h']], 'UnifiedSource-src_jsc_bindings-3.cpp', 'HomeNodeAsyncHooks.cpp'],
    [[['jsc/bindings/ScriptExecutionContext.cpp', 'ScriptExecutionContext.h']], 'UnifiedSource-src_jsc_bindings-4.cpp', 'HomeScriptExecutionContext.cpp'],
    [[['jsc/bindings/webcore/MessagePort.cpp', 'MessagePort.h'], ['jsc/bindings/webcore/JSWorker.cpp', 'JSWorker.h'], ['jsc/bindings/webcore/MessageEvent.cpp', 'MessageEvent.h'], ['jsc/bindings/webcore/JSWebSocket.cpp', 'JSWebSocket.h'], ['jsc/bindings/webcore/JSReadableStream.cpp', 'JSReadableStream.h']], 'UnifiedSource-src_jsc_bindings_webcore-3.cpp', 'HomeMessagePort.cpp'],
    [[['jsc/bindings/webcore/MessagePortPipe.cpp', 'MessagePortPipe.h'], ['jsc/bindings/webcore/ReadableStream.cpp', 'ReadableStream.h']], 'UnifiedSource-src_jsc_bindings_webcore-4.cpp', 'HomeMessagePortPipe.cpp'],
    [[['jsc/bindings/webcore/Worker.cpp', 'Worker.h'], ['jsc/bindings/webcore/WebSocket.cpp', 'WebSocket.h']], 'UnifiedSource-src_jsc_bindings_webcore-5.cpp', 'HomeWorker.cpp'],
    [[['jsc/bindings/BunWorkerGlobalScope.cpp', 'BunWorkerGlobalScope.h'], ['jsc/bindings/BunAnalyzeTranspiledModule.cpp', 'BunAnalyzeTranspiledModule.h'], ['jsc/bindings/AsyncContextFrame.cpp', 'AsyncContextFrame.h']], 'UnifiedSource-src_jsc_bindings-0.cpp', 'HomeBunWorkerGlobalScope.cpp'],
    [[['jsc/bindings/webcore/JSMessagePort.cpp', 'JSMessagePort.h'], ['jsc/bindings/webcore/JSMessageEvent.cpp', 'JSMessageEvent.h'], ['jsc/bindings/webcore/JSMIMEParams.cpp', 'JSMIMEParams.h']], 'UnifiedSource-src_jsc_bindings_webcore-2.cpp', 'HomeJSMessagePort.cpp'],
    [[['jsc/bindings/stringWidth.cpp', 'stringWidth.h'], ['jsc/bindings/sliceAnsi.cpp', 'sliceAnsi.h'], ['jsc/bindings/stripANSI.cpp', 'stripANSI.h'], ['jsc/bindings/wrapAnsi.cpp', 'wrapAnsi.h'], ['jsc/bindings/napi_finalizer.cpp', 'napi_finalizer.h']], 'UnifiedSource-src_jsc_bindings-5.cpp', 'HomeStringWidth.cpp'],
    [[['jsc/modules/NodeUtilTypesModule.cpp', 'NodeUtilTypesModule.h'], ['jsc/modules/NodeModuleModule.cpp', 'NodeModuleModule.h']], 'UnifiedSource-src_jsc_modules-0.cpp', 'HomeNodeUtilTypesModule.cpp'],
  ] as const).map(([sources, unifiedName, outputName]) => {
    const owned = sources.map(([relativeSource, abiHeader]) => {
      const source = path.join(homeSource, relativeSource)
      return { source, basename: path.basename(source), body: read(source), abiHeader, replacements: 0 }
    })
    const unifiedPath = path.join(externalBuild, 'unified', unifiedName)
    const unified = read(unifiedPath).replace(/^[ \t]*#include "([^"\r\n]+)"[ \t]*\r?$/gm, (_, relative) => {
      const externalSource = path.resolve(path.dirname(unifiedPath), relative)
      const selected = owned.find(item => item.basename === path.basename(relative))
      if (selected) {
        selected.replacements++
        if (selected.abiHeader) {
          const homeHeader = path.join(path.dirname(selected.source), selected.abiHeader)
          const externalHeader = path.join(path.dirname(externalSource), selected.abiHeader)
          assertClassHeaderAbi(readFileSync(homeHeader), readFileSync(externalHeader), selected.abiHeader, externalHeader)
        }
        return `#include ${JSON.stringify(selected.basename)}`
      }
      return `#include ${JSON.stringify(externalSource)}`
    })
    for (const selected of owned) {
      if (selected.replacements !== 1) throw new Error(`Native unified source must contain exactly one ${selected.basename}`)
    }
    return { owned, unified, outputName }
  })
  mkdirSync(output, { recursive: true })
  writeFileSync(path.join(output, 'NativeModuleImpl.h'), nativeModuleImpl)
  writeFileSync(path.join(output, 'NodeBufferModule.h'), bufferModuleHeader)
  writeFileSync(path.join(output, 'NodeStringDecoderModule.h'), stringDecoderModuleHeader)
  for (const { module, name, input, namedExports } of inputs) {
    // The cache lives under Home's type=commonjs package. Force ESM parsing so
    // Bun does not synthesize a CommonJS wrapper and an export inside the JSC
    // builtin function. A temporary directory outside this repo hid that bug.
    const inputPath = path.join(output, `${name}.mts`)
    writeFileSync(inputPath, input)
    const result = await Bun.build({
      entrypoints: [inputPath],
      target: 'bun',
      minify: { syntax: true, identifiers: false, whitespace: false, keepNames: true },
      external: builtinModules,
      define: { ...define, IS_BUN_DEVELOPMENT: 'false', __intrinsic__debug: 'false' },
    })
    if (!result.success || result.outputs.length !== 1) throw new AggregateError(result.logs, `Cannot bundle ${module}`)
    let bundled = await result.outputs[0].text()
    if (namedExports) {
      const marker = bundled.match(/\$\$EXPORT\$\$\((.*)\).\$\$EXPORT_END\$\$;/g)
      if (marker?.length !== 1) throw new Error(`Lost builtin export marker in ${module}`)
      bundled = lowerNamedBuiltinExports(bundled.replace(marker[0], ''), namedExports) + ';$$EXPORT$$($).$$EXPORT_END$$;'
    }
    const outputSyntax = new Bun.Transpiler({ loader: 'js' }).scan(bundled)
    if (outputSyntax.exports.length || outputSyntax.imports.length || /^\s*(?:export|import)\s/m.test(bundled)) {
      throw new Error(`Builtin output contains unresolved module syntax: ${module}`)
    }
    const exportPattern = /\$\$EXPORT\$\$\((.*)\).\$\$EXPORT_END\$\$;/g
    if ([...bundled.matchAll(exportPattern)].length !== 1) throw new Error(`Lost builtin export marker in ${module}`)
    if (bundled.includes('import.meta.require(')) throw new Error(`Unresolved builtin require in ${module}`)
    let captured = '(function () {"use strict";\n'
      + (bundled.includes('$assert') ? createAssertClientJS(module.replace(/\.ts$/, '')) : '')
      + bundled.replace('// @bun\n', '').replace(exportPattern, 'return $1')
        .replace(/]\s*,\s*__(debug|assert)_end__\)/g, ')')
        .replace(/__intrinsic__/g, '@').replace(/__no_intrinsic__/g, '')
      + '\n})\n'
    if (captured.includes('@bundleError(') || captured.includes('$$EXPORT')) throw new Error(`Invalid builtin output: ${module}`)
    captured = checkAscii(captured)
    constants = replaceModuleLiteral(constants, name, declareASCIILiteral(`${name}Code`, captured))
    writeFileSync(path.join(output, `${name}.js`), captured)
  }

  // `internal-for-testing` uses every kind of Bun native dispatch intrinsic,
  // while the incremental builtin pipeline intentionally owns only verified
  // C++ calls. Preserve Bun's ABI-matched generated function and insert the
  // Home test adapter at a stable declaration boundary instead of rebundling
  // the module and renumbering its @lazy dispatch slots.
  const internalForTestingName = moduleEnum('internal-for-testing.ts')
  requiredId(abi, internalForTestingName)
  const externalInternalForTesting = read(path.join(externalBuild, 'js/internal-for-testing.js'))
  if (!externalInternalForTesting.startsWith('(function (){"use strict";') || !externalInternalForTesting.endsWith('})\n')) {
    throw new Error('Unexpected generated internal-for-testing wrapper')
  }
  const declarationAnchor = ', exposedInternals = {'
  if (externalInternalForTesting.split(declarationAnchor).length !== 2) {
    throw new Error('Expected one generated exposedInternals declaration')
  }
  const streamModule = requireTransformer('node:stream', 'internal-for-testing.ts').replaceAll('__intrinsic__', '@')
  const adapterTemplate = read(path.resolve(import.meta.dir, '../packages/runtime/src/jsc/internal-stream-wrap.js'))
  if (adapterTemplate.split('__HOME_NODE_STREAM__').length !== 2) {
    throw new Error('Expected one node:stream placeholder in internal stream adapter')
  }
  const adapter = adapterTemplate.replace('__HOME_NODE_STREAM__', streamModule).trim()
  let capturedInternalForTesting = externalInternalForTesting.replace(
    declarationAnchor,
    `;\n${adapter}\nvar exposedInternals = {`,
  )
  const exposedAnchor = 'var exposedInternals = {\n'
  if (capturedInternalForTesting.split(exposedAnchor).length !== 2) {
    throw new Error('Expected one patched exposedInternals declaration')
  }
  capturedInternalForTesting = capturedInternalForTesting.replace(
    exposedAnchor,
    exposedAnchor
      + '  "internal/js_stream_socket": HomeJSStreamSocket,\n'
      + '  "internal/test/binding": { internalBinding: homeInternalTestBinding },\n',
  )
  capturedInternalForTesting = checkAscii(capturedInternalForTesting)
  constants = replaceModuleLiteral(
    constants,
    internalForTestingName,
    declareASCIILiteral(`${internalForTestingName}Code`, capturedInternalForTesting),
  )
  writeFileSync(path.join(output, `${internalForTestingName}.js`), capturedInternalForTesting)
  writeFileSync(path.join(output, 'InternalModuleRegistryConstants.h'), constants)

  // Own only the selected implementations; keep every other source of their
  // unified translation units ABI-matched to its external headers. Generate the
  // MessagePort, pipe lifecycle, Worker and worker builtin together: their private
  // contracts must never come from different builds.
  for (const { name, bytes } of privateHeaders) writeFileSync(path.join(output, name), bytes)
  for (const { owned, unified, outputName } of nativeUnits) {
    for (const { source, basename, body } of owned) {
      writeFileSync(path.join(output, basename), `#line 1 ${JSON.stringify(source)}\n${body}`)
    }
    writeFileSync(path.join(output, outputName), unified)
  }
  console.log(`Generated ${ownedModules.join(', ')} and the internal stream test adapter with verified linked ABI mappings`)
}

await main().catch(error => {
  // Fatal generation failures must not depend on buffered console output.
  writeSync(2, `${error instanceof Error ? error.stack || error.message : String(error)}\n`)
  process.exitCode = 1
})
