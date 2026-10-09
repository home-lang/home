import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { createInternalModuleRegistry } from '../packages/runtime/upstream/src/codegen/internal-module-registry-scanner'
import { setNativeCallResolver } from '../packages/runtime/upstream/src/codegen/generate-js2native'
import { enumValues, moduleEnum, nativeFunctionId, requiredId } from './native_module_abi'
import { decodeCoreBuiltins, replaceCoreBuiltins, validateCoreFamily } from './core_builtin_abi'
import NodeErrors from '../packages/runtime/upstream/src/jsc/bindings/ErrorCode'

export const ownedCoreFamilies = [
  'ByteLengthQueuingStrategy', 'CompressionStream', 'CountQueuingStrategy', 'DecompressionStream',
  'ReadableByteStreamController', 'ReadableByteStreamInternals', 'ReadableStream', 'ReadableStreamBYOBReader',
  'ReadableStreamBYOBRequest', 'ReadableStreamDefaultController', 'ReadableStreamDefaultReader', 'ReadableStreamInternals',
  'StreamInternals', 'TextDecoderStream', 'TextEncoderStream', 'TransformStream', 'TransformStreamDefaultController',
  'TransformStreamInternals', 'WritableStreamDefaultController', 'WritableStreamDefaultWriter', 'WritableStreamInternals',
]

async function main() {
  const [buildArg, outputArg] = process.argv.slice(2)
  if (!buildArg || !outputArg) throw new Error('Usage: bundle-core-builtins.ts <native-build> <output-directory>')
  const build = path.resolve(buildArg)
  const output = path.resolve(outputArg)
  const homeSource = path.resolve(import.meta.dir, '../packages/runtime/upstream/src')
  const generated = path.join(build, 'codegen')
  const read = (name: string) => readFileSync(path.join(generated, name), 'utf8')
  const header = read('WebCoreJSBuiltins.h')
  const cpp = read('WebCoreJSBuiltins.cpp')
  const baseline = decodeCoreBuiltins(cpp)
  const abi = enumValues(read('InternalModuleRegistry+enum.h'))
  const dispatch = read('GeneratedJS2Native.h')
  const errors = enumValues(read('ErrorCode+List.h'))
  let errorIndex = 0
  for (const [code, , , ...constructors] of NodeErrors) {
    if (requiredId(errors, code) !== errorIndex++) throw new Error(`Error ABI mismatch: ${code}`)
    for (const constructor of constructors) {
      if (constructor && requiredId(errors, `${code}_${constructor.name}`) !== errorIndex++) throw new Error(`Error ABI mismatch: ${code}_${constructor.name}`)
    }
  }
  setNativeCallResolver((type, file, symbol, length) => nativeFunctionId(dispatch, type, file, symbol, length))
  const registry = createInternalModuleRegistry(path.join(homeSource, 'js'))
  globalThis.requireTransformer = (specifier: string, from: string) => {
    const transformed = registry.requireTransformer(specifier, from)
    const match = transformed.match(/getInternalField\(__intrinsic__internalModuleRegistry, (\d+)\/\*/)
    if (!match) throw new Error(`Cannot resolve core builtin dependency: ${specifier}`)
    const id = requiredId(abi, moduleEnum(registry.moduleList[Number(match[1])]))
    return `(__intrinsic__getInternalField(__intrinsic__internalModuleRegistry, ${id}) || __intrinsic__createInternalModuleById(${id}))`
  }
  const staging = mkdtempSync(path.join(tmpdir(), 'home-core-builtins-'))
  try {
    globalThis.CMAKE_BUILD_ROOT = staging
    const { processFileSplit } = await import('../packages/runtime/upstream/src/codegen/bundle-functions')
    const replacements = new Map<string, string>()
    const manifest = []
    for (const family of ownedCoreFamilies) {
      const result = await processFileSplit(path.join(homeSource, 'js/builtins', `${family}.ts`))
      validateCoreFamily(header, family, result.functions, result.internal)
      for (const fn of result.functions) {
        const member = family[0].toLowerCase() + family.slice(1) + fn.name[0].toUpperCase() + fn.name.slice(1) + 'CodeSource'
        if (replacements.has(member)) throw new Error(`Duplicate owned core function ${member}`)
        if (fn.source.includes('import.meta.require(') || fn.source.includes('@bundleError(')) throw new Error(`Unresolved core builtin ${member}`)
        new Function(`return ${fn.source.replace(/@([A-Za-z_])/g, '__intrinsic__$1')}`)
        replacements.set(member, fn.source)
      }
      manifest.push({ family, source: path.join(homeSource, 'js/builtins', `${family}.ts`), functions: result.functions.length })
    }
    const replaced = replaceCoreBuiltins(cpp, replacements)
    mkdirSync(output, { recursive: true })
    writeFileSync(path.join(output, 'WebCoreJSBuiltins.h'), header)
    writeFileSync(path.join(output, 'WebCoreJSBuiltins.cpp'), replaced)
    for (const [member, source] of replacements) writeFileSync(path.join(output, `${member}.js`), source)
    writeFileSync(path.join(output, 'ownership.json'), `${JSON.stringify({ families: manifest, owned_functions: replacements.size, total_functions: baseline.functions.length }, null, 2)}\n`)
  } finally {
    rmSync(staging, { recursive: true, force: true })
  }
}

if (import.meta.main) await main()
