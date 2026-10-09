import { expect, test } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { decodeCoreBuiltins, replaceCoreBuiltins } from './core_builtin_abi'

const nativeBuild = path.dirname(process.env.HOME_BUN_OBJ_ROOT || '/Users/chris/Code/bun/build/release/obj')
const available = existsSync(path.join(nativeBuild, 'codegen/WebCoreJSBuiltins.cpp'))
const nativeTest = available ? test : test.skip
const read = (name: string) => readFileSync(path.join(nativeBuild, 'codegen', name), 'utf8')

nativeTest('core source replacement preserves all unowned functions and validates every source range', () => {
  const original = read('WebCoreJSBuiltins.cpp')
  const before = decodeCoreBuiltins(original)
  const member = 'readableStreamInternalsReadableStreamCancelCodeSource'
  const replacement = '(function(stream, reason) { "use strict"; return "$&"; })\n'
  const after = decodeCoreBuiltins(replaceCoreBuiltins(original, new Map([[member, replacement]])))
  expect(after.functions).toHaveLength(before.functions.length)
  for (const fn of before.functions) {
    expect(after.functions.find(x => x.member === fn.member)?.source).toBe(fn.member === member ? replacement : fn.source)
  }
  expect(() => replaceCoreBuiltins(original, new Map([['missingCodeSource', replacement]]))).toThrow('Linked core ABI has no')
  expect(() => replaceCoreBuiltins(original, new Map([[member, 'é']]))).toThrow('Invalid core source')
  expect(() => decodeCoreBuiltins(original.replace(/internalCombinedSource = \{ combinedSourceCodeBuffer, \d+ \};/, 'internalCombinedSource = { combinedSourceCodeBuffer, 0 };'))).toThrow('Invalid core builtin source span')
  expect(() => decodeCoreBuiltins(original.replace(/SourceCode\(sourceProvider.copyRef\(\), 0,/, 'SourceCode(sourceProvider.copyRef(), 1,'))).toThrow('Invalid or duplicate core source range')
})

nativeTest('generates core stream families with a byte-identical header and rejects ABI drift before output', () => {
  const temporary = mkdtempSync(path.join(tmpdir(), 'home-core-abi-'))
  const generator = path.join(import.meta.dir, 'bundle-core-builtins.ts')
  const run = (build: string, output: string) => Bun.spawnSync([process.execPath, generator, build, output], { stdout: 'pipe', stderr: 'pipe', timeout: 60000 })
  try {
    const baseline = path.join(temporary, 'baseline')
    const result = run(nativeBuild, baseline)
    expect(result.exitCode, result.stderr.toString()).toBe(0)
    expect(readFileSync(path.join(baseline, 'WebCoreJSBuiltins.h'))).toEqual(readFileSync(path.join(nativeBuild, 'codegen/WebCoreJSBuiltins.h')))
    const manifest = JSON.parse(readFileSync(path.join(baseline, 'ownership.json'), 'utf8'))
    expect(manifest.families).toHaveLength(21)
    expect(manifest.owned_functions).toBe(280)
    const original = decodeCoreBuiltins(read('WebCoreJSBuiltins.cpp'))
    const generated = decodeCoreBuiltins(readFileSync(path.join(baseline, 'WebCoreJSBuiltins.cpp'), 'utf8'))
    let retained = 0
    for (const fn of original.functions) {
      if (!existsSync(path.join(baseline, fn.member + '.js'))) {
        expect(generated.functions.find(x => x.member === fn.member)?.source).toBe(fn.source)
        retained++
      }
    }
    expect(retained).toBe(original.functions.length - manifest.owned_functions)
    const fixture = path.join(temporary, 'fixture')
    mkdirSync(path.join(fixture, 'codegen'), { recursive: true })
    for (const name of ['WebCoreJSBuiltins.cpp', 'WebCoreJSBuiltins.h', 'InternalModuleRegistry+enum.h', 'GeneratedJS2Native.h', 'ErrorCode+List.h']) writeFileSync(path.join(fixture, 'codegen', name), read(name))
    const header = read('WebCoreJSBuiltins.h')
    for (const [label, changed, error] of [
      ['arity', header.replace('macro(cancel, readableStreamCancel, 1)', 'macro(cancel, readableStreamCancel, 2)'), 'Core function signature mismatch: ReadableStream.cancel'],
      ['visibility', header.replace('s_readableStreamCancelCodeImplementationVisibility = JSC::ImplementationVisibility::Public;', 's_readableStreamCancelCodeImplementationVisibility = JSC::ImplementationVisibility::Private;'), 'Core ImplementationVisibility mismatch: ReadableStream.cancel'],
      ['set', header.replace(/    macro\(cancel, readableStreamCancel, 1\) \\\n/, ''), 'Core function set mismatch: ReadableStream'],
    ]) {
      expect(changed).not.toBe(header)
      writeFileSync(path.join(fixture, 'codegen/WebCoreJSBuiltins.h'), changed)
      const output = path.join(temporary, label)
      const rejected = run(fixture, output)
      expect(rejected.exitCode).toBe(1)
      expect(rejected.stderr.toString()).toContain(error)
      expect(existsSync(output)).toBe(false)
    }
  } finally {
    rmSync(temporary, { recursive: true, force: true })
  }
}, 120000)
