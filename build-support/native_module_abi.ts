// ABI checks for incrementally owning builtin modules while other bindings
// still come from the configured external native build.
export function enumValues(header: string): Map<string, number> {
  const result = new Map<string, number>()
  for (const match of header.matchAll(/^\s*([A-Za-z][A-Za-z0-9_]*)\s*=\s*(\d+),?\s*$/gm)) {
    if (result.has(match[1])) throw new Error(`Duplicate ABI enum ${match[1]}`)
    result.set(match[1], Number(match[2]))
  }
  if (result.size === 0) throw new Error('Empty native ABI enum')
  return result
}

export function moduleEnum(id: string): string {
  return id.replace(/\.[mc]?[tj]s$/, '').replace(/[^a-zA-Z0-9]+/g, ' ').split(' ')
    .map(x => ['jsc', 'ffi', 'vm', 'tls', 'os', 'ws', 'fs', 'dns'].includes(x)
      ? x.toUpperCase() : x[0].toUpperCase() + x.slice(1)).join('')
}

export function requiredId(values: Map<string, number>, name: string): number {
  const id = values.get(name)
  if (id === undefined) throw new Error(`Linked native ABI has no ${name}`)
  return id
}

export function nativeFunctionId(header: string, type: string, filename: string, symbol: string, length: number | null): number {
  // Wrapped functions need signature validation and Zig calls need matching
  // exported adapters. Do not silently treat either as a direct C++ factory.
  if (type !== 'cpp' || length !== null) throw new Error(`Unsupported incremental native call: ${type} ${symbol}`)
  if (!header.includes(`#include "${filename.replace(/\.cpp$/, '.h')}"`)) {
    throw new Error(`Linked native dispatch has no header for ${filename}`)
  }
  const matches = [...header.matchAll(/case (\d+): return ([A-Za-z_][A-Za-z0-9_:]*)\(global\);/g)]
    .filter(match => match[2] === symbol)
  if (matches.length !== 1) throw new Error(`Linked native dispatch must contain exactly one ${symbol}`)
  return Number(matches[0][1])
}

export function replaceModuleLiteral(header: string, name: string, replacement: string): string {
  const pattern = new RegExp(`static constexpr const char ${name}CodeBytes\\[\\d+\\] = \\{[^}]*\\};\\s*static constexpr ASCIILiteral ${name}Code = ASCIILiteral::fromLiteralUnsafe\\(${name}CodeBytes\\);`, 'g')
  const matches = [...header.matchAll(pattern)]
  if (matches.length !== 1) throw new Error(`Expected exactly one generated literal for ${name}`)
  return header.replace(pattern, () => replacement)
}
