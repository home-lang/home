#!/usr/bin/env node
// Compile and run every test declared in ts_lsp.zig in disjoint, bounded
// groups. The unfiltered test compile exceeds the agreed memory ceiling on
// this machine; imported packages have their own full test steps.
import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const source = readFileSync(resolve(repo, 'packages/ts_lsp/src/ts_lsp.zig'), 'utf8')
const names = [...source.matchAll(/^test "([^"]+)"/gm)].map(match => match[1])
if (names.length === 0 || new Set(names).size !== names.length || names.some(name => !name || name.includes(','))) {
  throw new Error('ts_lsp test names must be unique, nonempty, and contain no commas')
}

const shardCount = 8
const shards = Array.from({ length: shardCount }, () => [])
for (const [index, name] of names.entries()) shards[index % shardCount].push(name)
for (const [index, shard] of shards.entries()) {
  const selected = names.filter(name => shard.some(filter => name.includes(filter)))
  if (selected.length !== shard.length || selected.some((name, i) => name !== shard[i])) {
    // A full name can be a substring of another test name; that would run a
    // test in two shards, so stop rather than claiming disjoint coverage.
    throw new Error(`shard ${index + 1} overlaps another test name`)
  }
}

const arg = process.argv[2]
if (arg === '--list') {
  for (const [index, shard] of shards.entries()) console.log(`${index + 1}/${shardCount}: ${shard.length} tests`)
  console.log(`Total: ${names.length} unique tests`)
  process.exit(0)
}
if (process.argv.length > 3 || (arg && !/^--shard=[1-8]$/.test(arg))) {
  console.error('Usage: node scripts/tests/run-ts-lsp-shards.mjs [--list|--shard=1..8]')
  process.exit(2)
}

const selected = arg ? [Number(arg.at(-1)) - 1] : shards.map((_, index) => index)
for (const index of selected) {
  const shard = shards[index]
  console.log(`ts_lsp shard ${index + 1}/${shardCount}: ${shard.length} tests`)
  const result = spawnSync('perl', [
    'scripts/run-bounded.pl', '1200', 'zig', 'build', 'test',
    '-Dfilter=ts_lsp', `-Dts-lsp-test-filters=${shard.join(',')}`, '-j1',
  ], {
    cwd: repo,
    stdio: 'inherit',
    env: {
      ...process.env,
      HOME_RUN_MAX_MB: '3840',
      HOME_RUN_MIN_LEVEL: '40',
      HOME_RUN_CRIT_LEVEL: '15',
      HOME_RUN_LABEL: `ts_lsp shard ${index + 1}/${shardCount}`,
    },
  })
  if (result.error) throw result.error
  if (result.status !== 0) {
    console.error(`ts_lsp shard ${index + 1}/${shardCount} stopped with status ${result.status}`)
    process.exit(result.status ?? 1)
  }
}
console.log(`ts_lsp: ${selected.length === shardCount ? 'all' : 'selected'} shard(s) passed`)
