import { expect, test } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { replaceModuleLiteral } from './native_module_abi'

const root = path.resolve(import.meta.dir, '..')
const nativeBuild = path.dirname(process.env.HOME_BUN_OBJ_ROOT || '/Users/chris/Code/bun/build/release/obj')
const available = existsSync(path.join(nativeBuild, 'codegen/InternalModuleRegistryConstants.h'))
const nativeTest = available ? test : test.skip
const read = (file: string) => readFileSync(file, 'utf8')

nativeTest('generates script-only Home URL and workers and preserves other literals', () => {
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
    const external = read(path.join(nativeBuild, 'codegen/InternalModuleRegistryConstants.h'))
    const generated = read(path.join(output, 'InternalModuleRegistryConstants.h'))
    expect(generated).not.toBe(external)
    const stripOwned = (header: string) => replaceModuleLiteral(replaceModuleLiteral(header, 'NodeUrl', 'OWNED_URL'), 'NodeWorkerThreads', 'OWNED_WORKERS')
    expect(stripOwned(generated)).toBe(stripOwned(external))
    expect(read(path.join(output, 'HomeInternalModuleRegistry.cpp')))
      .toContain('#include "InternalModuleRegistry.cpp"')
    const portUnit = read(path.join(output, 'HomeMessagePort.cpp'))
    expect(portUnit).toContain('#include "MessagePort.cpp"')
    const externalUnit = read(path.join(nativeBuild, 'unified/UnifiedSource-src_jsc_bindings_webcore-3.cpp'))
    const expectedUnit = externalUnit.replace(/^#include "([^"]+)"$/gm, (_, relative) => path.basename(relative) === 'MessagePort.cpp'
      ? '#include "MessagePort.cpp"'
      : `#include ${JSON.stringify(path.resolve(nativeBuild, 'unified', relative))}`)
    expect(portUnit).toBe(expectedUnit)
    expect(read(path.join(output, 'MessagePort.cpp'))).toContain('vm.propertyNames->message, value')
  } finally {
    rmSync(output, { recursive: true })
  }
}, 20000)

nativeTest('rejects error and native-wrapper ABI drift before producing linkable artifacts', () => {
  const cache = path.join(root, '.zig-cache/tmp')
  mkdirSync(cache, { recursive: true })
  const temporary = mkdtempSync(path.join(cache, 'home-builtin-abi-test-'))
  const codegen = path.join(temporary, 'codegen')
  mkdirSync(codegen)
  mkdirSync(path.join(temporary, 'unified'))
  try {
    for (const file of ['InternalModuleRegistry+enum.h', 'GeneratedJS2Native.h', 'ErrorCode+List.h', 'InternalModuleRegistryConstants.h']) {
      writeFileSync(path.join(codegen, file), read(path.join(nativeBuild, 'codegen', file)))
    }
    for (const unified of ['unified/UnifiedSource-src_jsc_bindings-1.cpp', 'unified/UnifiedSource-src_jsc_bindings_webcore-3.cpp']) {
      writeFileSync(path.join(temporary, unified), read(path.join(nativeBuild, unified)))
    }
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
    const signature = 'globalObject, 1, "jsFunctionPostMessage"_s, jsFunctionPostMessage,'
    expect(wrappers).toContain(signature)
    writeFileSync(wrapperHeader, wrappers.replace(signature, 'globalObject, 2, "jsFunctionPostMessage"_s, jsFunctionPostMessage,'))
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
