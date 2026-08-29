import { expect, test } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { replaceModuleLiteral } from './native_module_abi'

const root = path.resolve(import.meta.dir, '..')
const nativeBuild = path.dirname(process.env.HOME_BUN_OBJ_ROOT || '/Users/chris/Code/bun/build/release/obj')
const available = existsSync(path.join(nativeBuild, 'codegen/InternalModuleRegistryConstants.h'))
const nativeTest = available ? test : test.skip
const read = (file: string) => readFileSync(file, 'utf8')
const units = ['UnifiedSource-src_jsc_bindings-1.cpp', 'UnifiedSource-src_jsc_bindings_webcore-3.cpp', 'UnifiedSource-src_jsc_bindings_webcore-4.cpp', 'UnifiedSource-src_jsc_bindings_webcore-5.cpp', 'UnifiedSource-src_jsc_bindings-0.cpp', 'UnifiedSource-src_jsc_bindings_webcore-2.cpp', 'UnifiedSource-src_jsc_bindings_webcore-1.cpp']

function createNativeFixture(temporary: string) {
  const codegen = path.join(temporary, 'codegen')
  const webcore = path.join(temporary, 'webcore')
  mkdirSync(codegen)
  mkdirSync(path.join(temporary, 'js'))
  mkdirSync(webcore)
  mkdirSync(path.join(temporary, 'unified'))
  for (const file of ['InternalModuleRegistry+enum.h', 'GeneratedJS2Native.h', 'ErrorCode+List.h', 'InternalModuleRegistryConstants.h']) {
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
      if (['MessagePort.cpp', 'MessagePortPipe.cpp', 'Worker.cpp', 'BunWorkerGlobalScope.cpp', 'JSMessagePort.cpp', 'JSWorker.cpp', 'BunAnalyzeTranspiledModule.cpp', 'JSAbortSignalCustom.cpp'].includes(basename)) {
        const header = basename === 'JSAbortSignalCustom.cpp' ? 'AbortSignal.h' : basename.replace(/\.cpp$/, '.h')
        writeFileSync(path.join(webcore, basename), readFileSync(externalSource))
        writeFileSync(path.join(webcore, header), readFileSync(path.join(path.dirname(externalSource), header)))
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
    for (const name of ['NodeUrl', 'NodeWorkerThreads']) {
      const source = read(path.join(output, name + '.js'))
      expect(source).not.toMatch(/^\s*(?:export|import)\s/m)
      expect(source).not.toContain('__commonJS')
      // Check complete function grammar without executing native intrinsics.
      expect(() => new Function(`return ${source.replace(/@([A-Za-z_])/g, '__intrinsic__$1')}`)).not.toThrow()
    }
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
    const stripOwned = (header: string) => replaceModuleLiteral(
      replaceModuleLiteral(replaceModuleLiteral(header, 'NodeUrl', 'OWNED_URL'), 'NodeWorkerThreads', 'OWNED_WORKERS'),
      'InternalForTesting',
      'OWNED_INTERNAL_FOR_TESTING',
    )
    expect(stripOwned(generated)).toBe(stripOwned(external))
    expect(read(path.join(output, 'HomeInternalModuleRegistry.cpp')))
      .toContain('#include "InternalModuleRegistry.cpp"')
    const materializer = path.join(root, 'packages/runtime/src/native/H2HeadersMaterializer.cpp')
    expect(read(path.join(output, 'HomeInternalModuleRegistry.cpp')))
      .toContain('#include "H2HeadersMaterializer.cpp"')
    expect(read(path.join(output, 'H2HeadersMaterializer.cpp')))
      .toBe(`#line 1 ${JSON.stringify(materializer)}\n${read(materializer)}`)
    for (const [basename, unitName] of [['MessagePort.cpp', units[1]], ['MessagePortPipe.cpp', units[2]], ['Worker.cpp', units[3]], ['BunWorkerGlobalScope.cpp', units[4]], ['JSMessagePort.cpp', units[5]], ['JSAbortSignalCustom.cpp', units[6]]]) {
      const generatedUnit = read(path.join(output, 'Home' + basename))
      const externalUnit = read(path.join(nativeBuild, 'unified', unitName))
      const ownedNames = basename === 'MessagePort.cpp' ? [basename, 'JSWorker.cpp']
        : basename === 'BunWorkerGlobalScope.cpp' ? [basename, 'BunAnalyzeTranspiledModule.cpp'] : [basename]
      const expectedUnit = externalUnit.replace(/^#include "([^"]+)"$/gm, (_, relative) => ownedNames.includes(path.basename(relative))
        ? `#include ${JSON.stringify(path.basename(relative))}`
        : `#include ${JSON.stringify(path.resolve(nativeBuild, 'unified', relative))}`)
      expect(generatedUnit).toBe(expectedUnit)
      const includes = [...generatedUnit.matchAll(/^#include "([^"]+)"$/gm)].map(match => match[1])
      expect(includes.filter(include => include === basename)).toHaveLength(1)
      const externalIncludes = [...externalUnit.matchAll(/^#include "([^"]+)"$/gm)]
      expect(includes.filter(include => path.isAbsolute(include))).toHaveLength(externalIncludes.length - ownedNames.length)
      for (const name of ownedNames) {
        const homeSource = path.join(root, 'packages/runtime/upstream/src/jsc/bindings', name.startsWith('Bun') ? '' : 'webcore', name)
        expect(read(path.join(output, name))).toBe(`#line 1 ${JSON.stringify(homeSource)}\n${read(homeSource)}`)
      }
    }
    for (const privateHeader of ['HomeMessagePortLifecycle.h', 'HomeWorkerSnapshots.h']) {
      expect(readFileSync(path.join(output, privateHeader)))
        .toEqual(readFileSync(path.join(root, 'packages/runtime/upstream/src/jsc/bindings/webcore', privateHeader)))
    }
    expect(existsSync(path.join(output, 'MessagePort.h'))).toBe(false)
    expect(existsSync(path.join(output, 'MessagePortPipe.h'))).toBe(false)
    expect(existsSync(path.join(output, 'Worker.h'))).toBe(false)
    expect(read(path.join(output, 'MessagePort.cpp'))).toContain('vm.propertyNames->message, value')
  } finally {
    rmSync(output, { recursive: true })
  }
}, 20000)

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
  } finally {
    rmSync(temporary, { recursive: true })
  }
}, 20000)

nativeTest('rejects owned native class-header drift and invalid native ownership before output', () => {
  const cache = path.join(root, '.zig-cache/tmp')
  mkdirSync(cache, { recursive: true })
  const temporary = mkdtempSync(path.join(cache, 'home-port-abi-test-'))
  try {
    const { webcore } = createNativeFixture(temporary)
    for (const header of ['MessagePort.h', 'MessagePortPipe.h', 'Worker.h', 'BunWorkerGlobalScope.h', 'JSMessagePort.h', 'JSWorker.h', 'BunAnalyzeTranspiledModule.h', 'AbortSignal.h']) {
      const headerPath = path.join(webcore, header)
      const original = readFileSync(headerPath)
      writeFileSync(headerPath, Buffer.concat([original, Buffer.from('\n// ABI drift fixture\n')]))
      const output = path.join(temporary, header + '-output')
      const result = generate(temporary, output)
      expect(result.signalCode).toBeUndefined()
      expect(result.exitCode).toBe(1)
      expect(existsSync(output)).toBe(false)
      writeFileSync(headerPath, original)
    }
    for (const [basename, unitName] of [['MessagePortPipe.cpp', units[2]], ['Worker.cpp', units[3]], ['JSWorker.cpp', units[1]], ['BunAnalyzeTranspiledModule.cpp', units[4]], ['JSAbortSignalCustom.cpp', units[6]]]) {
      const unit = path.join(temporary, 'unified', unitName)
      const original = read(unit)
      const ownedInclude = `#include ${JSON.stringify(path.join(webcore, basename))}`
      expect(original).toContain(ownedInclude)
      for (const [kind, invalid] of [['missing', original.replace(ownedInclude, '')], ['duplicate', original + ownedInclude + '\n']]) {
        writeFileSync(unit, invalid)
        const output = path.join(temporary, basename + '-' + kind + '-output')
        const result = generate(temporary, output)
        expect(result.signalCode).toBeUndefined()
        expect(result.exitCode).toBe(1)
        expect(existsSync(output)).toBe(false)
      }
      writeFileSync(unit, original)
    }
  } finally {
    rmSync(temporary, { recursive: true })
  }
}, 20000)
