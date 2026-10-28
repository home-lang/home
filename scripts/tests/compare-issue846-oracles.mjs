#!/usr/bin/env node
// Compare every #846 project with TypeScript 5.7.3 using the same config,
// working directory, CLI flags, and exact stdout/stderr/exit status. The
// explicit noEmit override keeps this audit read-only even when a new fixture
// forgets to set it in tsconfig.json. Build home-tsc before invoking this.
import { spawnSync } from 'node:child_process'
import { statSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const home = resolve(repo, 'zig-out/bin/home-tsc')
let homeMtime
try {
  homeMtime = statSync(home).mtimeMs
} catch {
  console.error('Missing home-tsc binary; run a guarded zig build home-tsc -j1 first')
  process.exit(2)
}
for (const source of [
  'build.zig',
  'packages/ts_checker/src/check.zig',
  'packages/ts_cli/src/tsc_main.zig',
  'packages/ts_program/src/ts_program.zig',
  'packages/ts_resolver/src/ts_resolver.zig',
]) {
  if (statSync(resolve(repo, source)).mtimeMs > homeMtime) {
    console.error(`home-tsc predates ${source}; run a guarded zig build home-tsc -j1 first`)
    process.exit(2)
  }
}
const version = spawnSync('tsc', ['--version'], { encoding: 'utf8' })
if (version.error || version.status !== 0 || version.stdout.trim() !== 'Version 5.7.3') {
  console.error('Expected tsc 5.7.3; got:', version.error?.message ?? version.stdout.trim())
  process.exit(2)
}

const files = spawnSync('rg', ['--files', 'packages/ts_cli/testdata', '-g', 'tsconfig*.json'], {
  cwd: repo,
  encoding: 'utf8',
})
if (files.error || files.status !== 0) {
  console.error('Could not enumerate fixture configs:', files.error?.message ?? files.stderr)
  process.exit(2)
}
const configs = files.stdout.trim().split('\n').filter(path => path.includes('/issue846-')).sort()
if (configs.length === 0) {
  console.error('No #846 fixture configs found')
  process.exit(2)
}

function run(command, config) {
  return spawnSync(command, ['-p', config.split('/').at(-1), '--pretty', 'false', '--noEmit'], {
    cwd: resolve(repo, dirname(config)),
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: 16 * 1024 * 1024,
  })
}

function excerpt(value, index) {
  const start = Math.max(0, index - 60)
  return JSON.stringify(value.slice(start, index + 180))
}

let mismatches = 0
for (const config of configs) {
  const oracle = run('tsc', config)
  const actual = run(home, config)
  if (oracle.error || actual.error || oracle.signal || actual.signal) {
    mismatches++
    console.log(`ERROR ${config}: oracle=${oracle.error?.message ?? oracle.signal ?? 'ok'} home=${actual.error?.message ?? actual.signal ?? 'ok'}`)
    continue
  }
  const streams = ['stdout', 'stderr']
  const different = streams.filter(stream => oracle[stream] !== actual[stream])
  if (oracle.status !== actual.status || different.length) {
    mismatches++
    console.log(`DIFF ${config}: exit ${oracle.status}/${actual.status}; ${different.join(', ') || 'streams equal'}`)
    for (const stream of different) {
      const left = oracle[stream]
      const right = actual[stream]
      let index = 0
      while (index < left.length && index < right.length && left[index] === right[index]) index++
      console.log(`  ${stream} at ${index}: tsc=${excerpt(left, index)} home=${excerpt(right, index)}`)
    }
  }
}
console.log(`Compared ${configs.length} #846 config streams: ${configs.length - mismatches} exact matches, ${mismatches} mismatches.`)
process.exit(mismatches === 0 ? 0 : 1)
