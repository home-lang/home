import { mkdirSync, readFileSync, writeFileSync, writeSync } from 'node:fs'
import path from 'node:path'
import { builtinModules } from 'node:module'
import { sliceSourceCode } from '../packages/runtime/upstream/src/codegen/builtin-parser'
import { createAssertClientJS } from '../packages/runtime/upstream/src/codegen/client-js'
import { setNativeCallResolver } from '../packages/runtime/upstream/src/codegen/generate-js2native'
import { declareASCIILiteral, checkAscii } from '../packages/runtime/upstream/src/codegen/helpers'
import { createInternalModuleRegistry } from '../packages/runtime/upstream/src/codegen/internal-module-registry-scanner'
import { define } from '../packages/runtime/upstream/src/codegen/replacements'
import NodeErrors from '../packages/runtime/upstream/src/jsc/bindings/ErrorCode'
import { assertClassHeaderAbi, enumValues, moduleEnum, nativeFunctionId, replaceModuleLiteral, requiredId } from './native_module_abi'

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
  const ownedModules = ['node/url.ts', 'node/worker_threads.ts']
  let constants = read(path.join(generated, 'InternalModuleRegistryConstants.h'))
  // Validate every owned module against the linked ABI before starting bundler
  // workers or writing output. A late module mismatch must not leave a partial
  // set of generated native contracts behind.
  const inputs = ownedModules.map(module => {
    const name = moduleEnum(module)
    requiredId(abi, name)
    const source = read(path.join(homeSource, 'js', module))
    const scanned = new Bun.Transpiler({ loader: 'ts' }).scan(source)
    if (scanned.imports.some(item => item.kind === 'import-statement') || !scanned.exports.includes('default')) {
      throw new Error(`Incremental builtin must use require and a default export: ${module}`)
    }
    const processed = sliceSourceCode(`{${source}`, true, specifier => requireTransformer(specifier, module))
    const input = `var $;\n${processed.result.slice(1).trim().replaceAll('__intrinsic__exports', '$')}\n;$$EXPORT$$($).$$EXPORT_END$$;\n`
    if (input.includes('__intrinsic__inherits')) throw new Error(`Unvalidated class ABI in ${module}`)
    return { module, name, input }
  })
  // Preflight native ownership and ABI layout before creating any output.
  // Class headers remain external; only the private constants header is copied.
  const privateHeader = 'HomeMessagePortLifecycle.h'
  const privateHeaderBytes = readFileSync(path.join(homeSource, 'jsc/bindings/webcore', privateHeader))
  const nativeUnits = ([
    ['jsc/bindings/InternalModuleRegistry.cpp', 'UnifiedSource-src_jsc_bindings-1.cpp', 'HomeInternalModuleRegistry.cpp', null],
    ['jsc/bindings/webcore/MessagePort.cpp', 'UnifiedSource-src_jsc_bindings_webcore-3.cpp', 'HomeMessagePort.cpp', 'MessagePort.h'],
    ['jsc/bindings/webcore/MessagePortPipe.cpp', 'UnifiedSource-src_jsc_bindings_webcore-4.cpp', 'HomeMessagePortPipe.cpp', 'MessagePortPipe.h'],
    ['jsc/bindings/webcore/Worker.cpp', 'UnifiedSource-src_jsc_bindings_webcore-5.cpp', 'HomeWorker.cpp', 'Worker.h'],
  ] as const).map(([relativeSource, unifiedName, outputName, abiHeader]) => {
    const source = path.join(homeSource, relativeSource)
    const basename = path.basename(source)
    const body = read(source)
    const unifiedPath = path.join(externalBuild, 'unified', unifiedName)
    let replacements = 0
    const unified = read(unifiedPath).replace(/^[ \t]*#include "([^"\r\n]+)"[ \t]*\r?$/gm, (_, relative) => {
      const externalSource = path.resolve(path.dirname(unifiedPath), relative)
      if (path.basename(relative) === basename) {
        replacements++
        if (abiHeader) {
          const homeHeader = path.join(path.dirname(source), abiHeader)
          const externalHeader = path.join(path.dirname(externalSource), abiHeader)
          assertClassHeaderAbi(readFileSync(homeHeader), readFileSync(externalHeader), abiHeader, externalHeader)
        }
        return `#include ${JSON.stringify(basename)}`
      }
      return `#include ${JSON.stringify(externalSource)}`
    })
    if (replacements !== 1) throw new Error(`Native unified source must contain exactly one ${basename}`)
    return { source, basename, body, unified, outputName }
  })
  mkdirSync(output, { recursive: true })
  for (const { module, name, input } of inputs) {
    // The cache lives under Home's type=commonjs package. Force ESM parsing so
    // Bun does not synthesize a CommonJS wrapper and an export inside the JSC
    // builtin function. A temporary directory outside this repo hid that bug.
    const inputPath = path.join(output, `${name}.mts`)
    writeFileSync(inputPath, input)
    const result = await Bun.build({
      entrypoints: [inputPath],
      target: 'bun',
      minify: { syntax: true, identifiers: false, whitespace: false },
      keepNames: true,
      external: builtinModules,
      define: { ...define, IS_BUN_DEVELOPMENT: 'false', __intrinsic__debug: 'false' },
    })
    if (!result.success || result.outputs.length !== 1) throw new AggregateError(result.logs, `Cannot bundle ${module}`)
    const bundled = await result.outputs[0].text()
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
  writeFileSync(path.join(output, 'InternalModuleRegistryConstants.h'), constants)

  // Own only the selected implementations; keep every other source of their
  // unified translation units ABI-matched to its external headers. Generate the
  // MessagePort, pipe lifecycle, Worker and worker builtin together: their private
  // contracts must never come from different builds.
  writeFileSync(path.join(output, privateHeader), privateHeaderBytes)
  for (const { source, basename, body, unified, outputName } of nativeUnits) {
    writeFileSync(path.join(output, basename), `#line 1 ${JSON.stringify(source)}\n${body}`)
    writeFileSync(path.join(output, outputName), unified)
  }
  console.log(`Generated ${ownedModules.join(', ')} from Home with verified linked ABI mappings`)
}

await main().catch(error => {
  // Fatal generation failures must not depend on buffered console output.
  writeSync(2, `${error instanceof Error ? error.stack || error.message : String(error)}\n`)
  process.exitCode = 1
})
