#!/usr/bin/env node
// Exercise the public project compiler against the installed native 7.0.2
// reference. Classic TypeScript 5.7 has a different default for `strict`.
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const repo = resolve(fileURLToPath(new URL('../..', import.meta.url)))
const native = process.env.TSGO_BIN || resolve(repo, 'bench/vs_tsgo/.tools/tsgo/node_modules/@typescript/typescript-darwin-arm64/lib/tsc')
const home = process.env.HOME_TSC_BIN || resolve(repo, 'zig-out/bin/home-tsc')
const globals = `interface Array<T> {}
interface Boolean {}
interface CallableFunction {}
interface Function {}
interface IArguments {}
interface NewableFunction {}
interface Number {}
interface Object {}
interface RegExp {}
interface String {}
interface Promise<T> {}
interface PromiseConstructor {}
interface SymbolConstructor {}
`

const cases = [
  { name: 'noLib Promise declaration', options: { noLib: true, strict: true }, source: 'declare var Promise: any;\n', expected: [] },
  { name: 'noLib Symbol declaration', options: { noLib: true, strict: true }, source: 'declare var Symbol: any;\n', expected: [] },
  { name: 'empty lib Promise declaration', options: { lib: [], strict: true }, source: 'declare var Promise: any;\n', expected: [] },
  { name: 'noLib missing Promise value', options: { noLib: true, strict: true }, source: 'const result = import("./shared");\n', expected: [2468, 2712], shared: true },
  { name: 'authored constructors', options: { noLib: true, strict: true }, source: 'declare var Promise: PromiseConstructor; declare var Symbol: SymbolConstructor;\n', expected: [] },
  { name: 'default lib Promise conflict', options: { strict: true }, source: 'declare var Promise: any;\n', expected: [2403] },
  { name: 'default lib Symbol conflict', options: { strict: true }, source: 'declare var Symbol: any;\n', expected: [2403] },
  { name: 'Promise fragment conflict', options: { lib: ['es5', 'es2015.promise'], strict: true }, source: 'declare var Promise: any;\n', expected: [2403] },
  { name: 'Promise fragment leaves Symbol free', options: { lib: ['es5', 'es2015.promise'], strict: true }, source: 'declare var Symbol: any;\n', expected: [] },
  { name: 'Symbol fragment conflict', options: { lib: ['es5', 'es2015.symbol'], strict: true }, source: 'declare var Symbol: any;\n', expected: [2403] },
  { name: 'Symbol fragment leaves Promise free', options: { lib: ['es5', 'es2015.symbol'], strict: true }, source: 'declare var Promise: any;\n', expected: [] },
  { name: 'strict omitted', options: { noLib: true }, source: 'export function echo(value) { return value; }\n', expected: [7006] },
  { name: 'strict false', options: { noLib: true, strict: false }, source: 'export function echo(value) { return value; }\n', expected: [] },
  { name: 'strict true', options: { noLib: true, strict: true }, source: 'export function echo(value) { return value; }\n', expected: [7006] },
  { name: 'strict true, noImplicitAny false', options: { noLib: true, strict: true, noImplicitAny: false }, source: 'export function echo(value) { return value; }\n', expected: [] },
  { name: 'strict false, noImplicitAny true', options: { noLib: true, strict: false, noImplicitAny: true }, source: 'export function echo(value) { return value; }\n', expected: [7006] },
  { name: 'CLI strict omitted', options: {}, source: 'export function echo(value) { return value; }\n', expected: [7006], args: ['globals.d.ts', 'entry.ts', '--ignoreConfig', '--noLib', '--noEmit', '--target', 'ESNext', '--module', 'ESNext', '--pretty', 'false'] },
  { name: 'CLI strict false', options: {}, source: 'export function echo(value) { return value; }\n', expected: [], args: ['globals.d.ts', 'entry.ts', '--ignoreConfig', '--noLib', '--noEmit', '--target', 'ESNext', '--module', 'ESNext', '--strict', 'false', '--pretty', 'false'] },
  { name: 'CLI strict true', options: {}, source: 'export function echo(value) { return value; }\n', expected: [7006], args: ['globals.d.ts', 'entry.ts', '--ignoreConfig', '--noLib', '--noEmit', '--target', 'ESNext', '--module', 'ESNext', '--strict', 'true', '--pretty', 'false'] },
]

const version = spawnSync(native, ['--version'], { encoding: 'utf8' })
if (version.status !== 0 || version.stdout.trim() !== 'Version 7.0.2') {
  throw new Error(`expected native TypeScript 7.0.2: ${version.error?.message || version.stdout || version.stderr}`)
}
let passed = 0
for (const test of cases) {
  const directory = mkdtempSync(resolve(tmpdir(), 'home-ts-options-'))
  try {
    writeFileSync(resolve(directory, 'globals.d.ts'), globals)
    writeFileSync(resolve(directory, 'entry.ts'), test.source)
    if (test.shared) writeFileSync(resolve(directory, 'shared.ts'), 'export const marker = 1;\n')
    writeFileSync(resolve(directory, 'tsconfig.json'), JSON.stringify({
      files: ['globals.d.ts', 'entry.ts', ...(test.shared ? ['shared.ts'] : [])],
      compilerOptions: { target: 'ESNext', module: 'ESNext', noEmit: true, types: [], ...test.options },
    }))
    const run = bin => spawnSync(bin, test.args || ['-p', 'tsconfig.json', '--pretty', 'false'], { cwd: directory, encoding: 'utf8' })
    const reference = run(native)
    const actual = run(home)
    const codes = [...reference.stdout.matchAll(/error TS(\d+):/g)].map(match => Number(match[1]))
    if (reference.error || actual.error ||
        JSON.stringify(codes) !== JSON.stringify(test.expected) ||
        reference.stdout !== actual.stdout || reference.stderr !== actual.stderr ||
        (reference.status === 0) !== (actual.status === 0)) {
      console.error(`${test.name}: MISMATCH\nexpected codes ${test.expected}\nreference (${reference.status}): ${reference.stdout}${reference.stderr}\nhome (${actual.status}): ${actual.stdout}${actual.stderr}`)
      process.exitCode = 1
    } else {
      passed++
    }
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}
console.log(`${passed}/${cases.length} native TypeScript 7.0.2 option comparisons exact`)
