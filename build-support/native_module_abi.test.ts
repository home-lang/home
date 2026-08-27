import { describe, expect, test } from 'bun:test'
import { enumValues, moduleEnum, nativeFunctionId, replaceModuleLiteral, requiredId } from './native_module_abi'

describe('incremental native module ABI', () => {
  test('uses external IDs, including zero, and rejects absent identities', () => {
    const values = enumValues('BunFFI = 0,\nNodeUrl = 144,\nInternalUrl = 81,')
    expect(requiredId(values, moduleEnum('bun/ffi.ts'))).toBe(0)
    expect(requiredId(values, moduleEnum('node/url.ts'))).toBe(144)
    expect(requiredId(values, moduleEnum('internal/url.ts'))).toBe(81)
    expect(() => requiredId(values, 'Missing')).toThrow('no Missing')
    expect(() => enumValues('')).toThrow('Empty')
    expect(() => enumValues('NodeUrl = 1,\nNodeUrl = 2,')).toThrow('Duplicate')
  })
  test('resolves exact native factory and rejects unsupported or ambiguous dispatch', () => {
    const header = '#include "NodeURL.h"\ncase 87: return Bun::createNodeURLBinding(global);'
    expect(nativeFunctionId(header, 'cpp', 'NodeURL.cpp', 'Bun::createNodeURLBinding', null)).toBe(87)
    for (const [type, file, symbol, length] of [
      ['zig', 'NodeURL.cpp', 'Bun::createNodeURLBinding', null],
      ['cpp', 'NodeURL.cpp', 'Bun::createNodeURLBinding', 1],
      ['cpp', 'Other.cpp', 'Bun::createNodeURLBinding', null],
      ['cpp', 'NodeURL.cpp', 'Bun::missing', null],
    ] as const) {
      expect(() => nativeFunctionId(header, type, file, symbol, length)).toThrow()
    }
    expect(() => nativeFunctionId(header + '\ncase 88: return Bun::createNodeURLBinding(global);',
      'cpp', 'NodeURL.cpp', 'Bun::createNodeURLBinding', null)).toThrow('exactly one')
  })
  test('replaces only the owned literal without interpreting replacement dollar syntax', () => {
    const literal = 'static constexpr const char NodeUrlCodeBytes[3] = {1,2,0};\nstatic constexpr ASCIILiteral NodeUrlCode = ASCIILiteral::fromLiteralUnsafe(NodeUrlCodeBytes);'
    expect(replaceModuleLiteral('before\n' + literal + '\nafter', 'NodeUrl', '$& replacement'))
      .toBe('before\n$& replacement\nafter')
    expect(() => replaceModuleLiteral('', 'NodeUrl', '')).toThrow('exactly one')
    expect(() => replaceModuleLiteral(literal + literal, 'NodeUrl', '')).toThrow('exactly one')
  })
  test('validates the complete C++ wrapper signature before resolving its dispatch', () => {
    const wrapper = 'static ALWAYS_INLINE JSC::JSValue js2native_wrap_jsFunctionPostMessage(Zig::GlobalObject* globalObject) {\n  return JSC::JSFunction::create(globalObject->vm(), globalObject, 1, "jsFunctionPostMessage"_s, jsFunctionPostMessage, JSC::ImplementationVisibility::Public);\n}'
    const header = '#include "ZigGlobalObject.h"\n' + wrapper + '\ncase 94: return js2native_wrap_jsFunctionPostMessage(global);'
    const resolve = (source: string, length = 1) => nativeFunctionId(source, 'cpp', 'ZigGlobalObject.cpp', 'jsFunctionPostMessage', length)
    expect(resolve(header)).toBe(94)
    expect(() => resolve(header, 2)).toThrow('signature mismatch')
    expect(() => resolve(header, -1)).toThrow('Invalid')
    expect(() => resolve(header.replace(', jsFunctionPostMessage,', ', wrongFunction,'))).toThrow('signature mismatch')
    expect(() => resolve(header.replace('Visibility::Public', 'Visibility::Private'))).toThrow('signature mismatch')
    expect(() => resolve(header + '\n' + wrapper)).toThrow('signature mismatch')
    expect(() => resolve(header + '\ncase 95: return js2native_wrap_jsFunctionPostMessage(global);')).toThrow('exactly one')
  })
})
