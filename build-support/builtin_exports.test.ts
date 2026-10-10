import { expect, test } from 'bun:test'
import { lowerNamedBuiltinExports } from './builtin_exports'

test('native named exports retain aliases, identity and enumerable properties', () => {
  const source = 'const value = { answer: 42 }; function callable() { return value };\nexport { callable as run, value, };\n'
  const lowered = lowerNamedBuiltinExports(source, ['value', 'run'])
  const exports = new Function(lowered + '\nreturn $;')()
  expect(exports.run()).toBe(exports.value)
  expect(exports.run.name).toBe('callable')
  expect(Object.keys(exports)).toEqual(['run', 'value'])
  expect(exports.value.answer).toBe(42)
})

test('native named export lowering rejects unresolved grammar and identity drift', () => {
  for (const [source, names] of [
    ['export { value };', ['value']],
    ['\nexport { value };\notherCode()', ['value']],
    ['\nexport { value } from "other";', ['value']],
    ['\nexport { value as publicValue };', ['value']],
    ['\nexport { value, value };', ['value']],
    ['\nexport { value as publicValue, other as publicValue };', ['publicValue']],
  ] as const) expect(() => lowerNamedBuiltinExports(source, names)).toThrow()
})
