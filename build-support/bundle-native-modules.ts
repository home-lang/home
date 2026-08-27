import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { builtinModules } from 'node:module'
import { sliceSourceCode } from '../packages/runtime/upstream/src/codegen/builtin-parser'
import { createAssertClientJS } from '../packages/runtime/upstream/src/codegen/client-js'
import { setNativeCallResolver } from '../packages/runtime/upstream/src/codegen/generate-js2native'
import { declareASCIILiteral, checkAscii } from '../packages/runtime/upstream/src/codegen/helpers'
import { createInternalModuleRegistry } from '../packages/runtime/upstream/src/codegen/internal-module-registry-scanner'
import { define } from '../packages/runtime/upstream/src/codegen/replacements'
import NodeErrors from '../packages/runtime/upstream/src/jsc/bindings/ErrorCode'
import { enumValues, moduleEnum, nativeFunctionId, replaceModuleLiteral, requiredId } from './native_module_abi'

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
const ownedModules = ['node/url.ts']
let constants = read(path.join(generated, 'InternalModuleRegistryConstants.h'))
mkdirSync(output, { recursive: true })
for (const module of ownedModules) {
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

// Own the registry implementation; keep the other sources of this unified
// translation unit ABI-matched to their external headers until ported too.
const registrySource = path.join(homeSource, 'jsc/bindings/InternalModuleRegistry.cpp')
writeFileSync(path.join(output, 'InternalModuleRegistry.cpp'), `#line 1 ${JSON.stringify(registrySource)}\n${read(registrySource)}`)
const unifiedPath = path.join(externalBuild, 'unified/UnifiedSource-src_jsc_bindings-1.cpp')
let replacements = 0
const unified = read(unifiedPath).replace(/^#include "([^"]+)"$/gm, (_, relative) => {
  if (path.basename(relative) === 'InternalModuleRegistry.cpp') {
    replacements++
    return '#include "InternalModuleRegistry.cpp"'
  }
  return `#include ${JSON.stringify(path.resolve(path.dirname(unifiedPath), relative))}`
})
if (replacements !== 1) throw new Error('Native unified source must contain exactly one InternalModuleRegistry.cpp')
writeFileSync(path.join(output, 'HomeInternalModuleRegistry.cpp'), unified)
console.log(`Generated ${ownedModules.join(', ')} from Home with verified linked ABI mappings`)
