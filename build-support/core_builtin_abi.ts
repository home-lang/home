export interface CoreFunction {
  member: string
  start: number
  end: number
  source: string
}

export function decodeCoreBuiltins(cpp: string): { functions: CoreFunction[], buffer: string } {
  const arrays = [...cpp.matchAll(/static const Latin1Character combinedSourceCodeBuffer\[(\d+)\] = \{ ([\d, ]+), 0 \};/g)]
  if (arrays.length !== 1) throw new Error('Expected one core builtin buffer')
  const bytes = arrays[0][2].split(',').map(x => Number(x.trim()))
  if (bytes.some(x => !Number.isInteger(x) || x < 0 || x > 127) || bytes.length + 1 !== Number(arrays[0][1])) {
    throw new Error('Invalid core builtin ASCII buffer length or byte')
  }
  const spans = [...cpp.matchAll(/internalCombinedSource = \{ combinedSourceCodeBuffer, (\d+) \};/g)]
  if (spans.length !== 1 || Number(spans[0][1]) !== bytes.length) throw new Error('Invalid core builtin source span')
  const buffer = Buffer.from(bytes).toString('ascii')
  const functions = [...cpp.matchAll(/m_(\w+CodeSource)\(SourceCode\(sourceProvider.copyRef\(\), (\d+), (\d+), 1, 1\)\)/g)]
    .map(match => ({ member: match[1], start: Number(match[2]), end: Number(match[3]), source: buffer.slice(Number(match[2]), Number(match[3])) }))
    .sort((a, b) => a.start - b.start)
  let end = 0
  const members = new Set<string>()
  for (const fn of functions) {
    if (fn.start !== end || fn.end <= fn.start || fn.end > buffer.length || members.has(fn.member)) {
      throw new Error(`Invalid or duplicate core source range: ${fn.member}`)
    }
    members.add(fn.member)
    end = fn.end
  }
  if (end !== buffer.length) throw new Error('Core source ranges do not cover the buffer')
  return { functions, buffer }
}

export function replaceCoreBuiltins(cpp: string, replacements: Map<string, string>): string {
  const decoded = decodeCoreBuiltins(cpp)
  const remaining = new Set(replacements.keys())
  const offsets = new Map<string, [number, number]>()
  let buffer = ''
  for (const fn of decoded.functions) {
    const source = replacements.get(fn.member) ?? fn.source
    if (!source || /[^\x00-\x7f]/.test(source)) throw new Error(`Invalid core source: ${fn.member}`)
    offsets.set(fn.member, [buffer.length, buffer.length + source.length])
    buffer += source
    remaining.delete(fn.member)
  }
  if (remaining.size) throw new Error(`Linked core ABI has no ${[...remaining].join(', ')}`)
  let output = cpp.replace(/static const Latin1Character combinedSourceCodeBuffer\[\d+\] = \{ [\d, ]+, 0 \};/, () =>
    `static const Latin1Character combinedSourceCodeBuffer[${buffer.length + 1}] = { ${[...Buffer.from(buffer)].join(',')}, 0 };`)
    .replace(/internalCombinedSource = \{ combinedSourceCodeBuffer, \d+ \};/, () =>
      `internalCombinedSource = { combinedSourceCodeBuffer, ${buffer.length} };`)
  output = output.replace(/m_(\w+CodeSource)\(SourceCode\(sourceProvider.copyRef\(\), \d+, \d+, 1, 1\)\)/g, (_, member) => {
    const [start, end] = offsets.get(member)!
    return `m_${member}(SourceCode(sourceProvider.copyRef(), ${start}, ${end}, 1, 1))`
  })
  const verified = decodeCoreBuiltins(output)
  for (const fn of verified.functions) {
    const original = decoded.functions.find(x => x.member === fn.member)!
    if (fn.source !== (replacements.get(fn.member) ?? original.source)) throw new Error(`Core source retention mismatch: ${fn.member}`)
  }
  return output
}

export function validateCoreFamily(header: string, family: string, functions: Array<{
  name: string, params: string[], constructAbility: string, constructKind: string,
  visibility: string, overriddenName: string, directives: Record<string, unknown>,
}>, internal: boolean): void {
  const lower = family[0].toLowerCase() + family.slice(1)
  const data = header.match(new RegExp(`#define WEBCORE_FOREACH_${family.toUpperCase()}_BUILTIN_DATA\\(macro\\) ([\\s\\S]*?)\\n\\n`))
  if (!data) throw new Error(`Linked core ABI has no family ${family}`)
  const entries = [...data[1].matchAll(/macro\((\w+), (\w+), (\d+)\)/g)]
  if (entries.length !== functions.length) throw new Error(`Core function set mismatch: ${family}`)
  if (header.includes(`class ${family}BuiltinFunctions {`) !== internal) throw new Error(`Core internal visibility mismatch: ${family}`)
  for (const [index, fn] of functions.entries()) {
    const name = lower + fn.name[0].toUpperCase() + fn.name.slice(1)
    if (entries[index][1] !== fn.name || entries[index][2] !== name || Number(entries[index][3]) !== fn.params.length) {
      throw new Error(`Core function signature mismatch: ${family}.${fn.name}`)
    }
    for (const [kind, value] of [
      ['ConstructAbility', fn.constructAbility], ['InlineAttribute', fn.directives.alwaysInline ? 'Always' : 'None'],
      ['ConstructorKind', fn.constructKind], ['ImplementationVisibility', fn.visibility],
    ]) {
      if (!header.includes(`s_${name}Code${kind} = JSC::${kind}::${value};`)) throw new Error(`Core ${kind} mismatch: ${family}.${fn.name}`)
    }
    if (!header.includes(`macro(${name}Code, ${fn.name}, ${fn.overriddenName}, s_${name}CodeLength)`)) {
      throw new Error(`Core function name mismatch: ${family}.${fn.name}`)
    }
  }
}
