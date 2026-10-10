// Native registry modules return their export object from a JSC builtin body.
// Bun's bundler resolves/reorders named exports first, including local aliases.
export function lowerNamedBuiltinExports(source: string, expectedNames: readonly string[]): string {
  const match = source.match(/\nexport\s*\{([^}]*)\};?\s*$/)
  if (!match) throw new Error('Expected one trailing named builtin export clause')
  const entries = match[1].split(',').map(entry => entry.trim()).filter(Boolean).map(entry => {
    const parts = entry.match(/^([A-Za-z_$][A-Za-z0-9_$]*)(?:\s+as\s+([A-Za-z_$][A-Za-z0-9_$]*))?$/)
    if (!parts) throw new Error(`Unsupported builtin export binding: ${entry}`)
    return { local: parts[1], name: parts[2] || parts[1] }
  })
  const names = entries.map(entry => entry.name).sort()
  if (new Set(names).size !== names.length || JSON.stringify(names) !== JSON.stringify([...expectedNames].sort())) {
    throw new Error('Bundled builtin export identities differ from the source')
  }
  const object = `{${entries.map(entry => `${JSON.stringify(entry.name)}: ${entry.local}`).join(', ')}}`
  return source.slice(0, match.index) + `\nvar $ = ${object};\n`
}
