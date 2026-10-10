import { describe, expect, test } from 'bun:test'
import { assertClassHeaderAbi, enumValues, moduleEnum, nativeFunctionId, replaceModuleLiteral, requiredId } from './native_module_abi'

describe('incremental native module ABI', () => {
  test('requires byte-identical class headers and reports the selected external ABI path', () => {
    const original = new Uint8Array([0, 127, 255])
    expect(() => assertClassHeaderAbi(original, original.slice(), 'MessagePort.h', '/external/MessagePort.h')).not.toThrow()
    for (const changed of [new Uint8Array([0, 127, 254]), original.slice(0, 2), new Uint8Array([0, 127, 255, 0])]) {
      expect(() => assertClassHeaderAbi(original, changed, 'MessagePort.h', '/external/MessagePort.h'))
        .toThrow('Native class ABI mismatch: MessagePort.h differs from /external/MessagePort.h')
    }
  })
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
  test('validates Zig host source identity, declaration and complete wrapper signature', () => {
    const host = 'JS2Zig___src_jsc_ipc_zig__emitHandleIPCMessage'
    const wrapper = `static ALWAYS_INLINE JSC::JSValue js2native_wrap_emitHandleIPCMessage(Zig::GlobalObject* globalObject) { return JSC::JSFunction::create(globalObject->vm(), globalObject, 3, "emitHandleIPCMessage"_s, ${host}, JSC::ImplementationVisibility::Public); }`
    const header = `BUN_DECLARE_HOST_FUNCTION(${host});\n${wrapper}\ncase 169: return js2native_wrap_emitHandleIPCMessage(global);`
    const resolve = (source: string, file = 'src/jsc/ipc.zig', length: number | null = 3) => nativeFunctionId(source, 'zig', file, 'emitHandleIPCMessage', length)
    expect(resolve(header)).toBe(169)
    expect(() => resolve(header, 'src/other/ipc.zig')).toThrow('no host declaration')
    expect(() => resolve(header, '../src/jsc/ipc.zig')).toThrow('Unsupported')
    expect(() => resolve(header, 'src/jsc/ipc.zig', null)).toThrow('factory signature mismatch')
    expect(() => resolve(header, 'src/jsc/ipc.zig', 2)).toThrow('signature mismatch')
    expect(() => resolve(header.replace(`BUN_DECLARE_HOST_FUNCTION(${host});`, ''))).toThrow('no host declaration')
    expect(() => resolve(header.replace(`, ${host},`, ', missingHost,'))).toThrow('signature mismatch')
    expect(() => resolve(header + '\ncase 170: return js2native_wrap_emitHandleIPCMessage(global);')).toThrow('exactly one')
  })
  test('validates the encoded-value adapter for bare Zig factories', () => {
    const target = 'JS2Zig___src_runtime_node_node_net_binding_zig__getDefaultAutoSelectFamily'
    const declaration = `extern "C" SYSV_ABI JSC::EncodedJSValue ${target}_workaround(Zig::GlobalObject*);`
    const wrapper = `static ALWAYS_INLINE JSC::JSValue ${target}(Zig::GlobalObject* global) { return JSValue::decode(${target}_workaround(global)); }`
    const header = `${declaration}\n${wrapper}\ncase 101: return ${target}(global);`
    const resolve = (source: string) => nativeFunctionId(source, 'zig', 'src/runtime/node/node_net_binding.zig', 'getDefaultAutoSelectFamily', null)
    expect(resolve(header)).toBe(101)
    expect(() => resolve(header.replace(declaration, ''))).toThrow('factory signature mismatch')
    expect(() => resolve(header + '\n' + declaration)).toThrow('factory signature mismatch')
    expect(() => nativeFunctionId(header, 'zig', 'src/runtime/node/node_net_binding.zig', 'getDefaultAutoSelectFamily;', null)).toThrow('Invalid native symbol')
    expect(() => resolve(header.replace(`decode(${target}_workaround(global))`, 'decode(wrong(global))'))).toThrow('factory signature mismatch')
    expect(() => resolve(header + '\n' + wrapper)).toThrow('factory signature mismatch')
    expect(() => resolve(header + `\ncase 102: return ${target}(global);`)).toThrow('exactly one')
  })
})
