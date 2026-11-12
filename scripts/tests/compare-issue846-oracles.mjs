#!/usr/bin/env node
// Compare admitted-JavaScript projects and related checker regressions
// with TypeScript 5.7.3 using the same config,
// working directory, CLI flags, and exact stdout/stderr/exit status. The
// explicit noEmit override keeps this audit read-only even when a new fixture
// forgets to set it in tsconfig.json. Build home-tsc before invoking this.
//
// One thing is NOT taken from TypeScript 5.7.3: the order of a union's members.
// 5.7.3 prints type-allocation order, which is not reproducible and changes
// with skipLibCheck (#975). Native TypeScript 7 sorts members
// deterministically and owns that order (decided 2026-11-11). See
// `nativeOrderConfigs` below.
import { spawnSync } from 'node:child_process'
import { readdirSync, statSync } from 'node:fs'
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
  // A successful `zig build home-tsc` may reuse an unchanged cached binary
  // after test-only build.zig edits. Source mtimes still catch stale checker
  // semantics; Zig's build graph owns build-configuration invalidation.
  'packages/ts_checker/src/check.zig',
  'packages/ts_checker/src/checked_transfer.zig',
  'packages/ts_cli/src/tsc_main.zig',
  'packages/ts_program/src/checked_schema.zig',
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

// Enumerate with Node rather than ripgrep: the audit must run on a machine
// that has no rg, and a missing binary previously stopped it before the first
// comparison.
function fixtureConfigs(directory) {
  const found = []
  for (const entry of readdirSync(resolve(repo, directory), { withFileTypes: true })) {
    const path = `${directory}/${entry.name}`
    if (entry.isDirectory()) found.push(...fixtureConfigs(path))
    else if (entry.name.startsWith('tsconfig') && entry.name.endsWith('.json')) found.push(path)
  }
  return found
}
const configs = fixtureConfigs('packages/ts_cli/testdata').filter(path =>
  path.includes('/issue846-') || path.includes('/issue965-') ||
  path.includes('/issue966-commonjs-constructor/') ||
  path.includes('/issue968-js-constructor-import/') ||
  path.includes('/issue963-aggregate-type-parameter/') ||
  path.includes('/issue960-readonly-own-methods/') ||
  path.includes('/issue972-generic-array-union-map/') ||
  path.includes('/issue970-unique-symbol-keyof/') ||
  path.includes('/issue971-object-display/') ||
  path.includes('/issue969-iterator-helpers/') ||
  path.includes('/issue987-array-statics/') ||
  path.includes('/issue988-entry-tuple/') ||
  path.includes('/issue989-spread-array-literal/') ||
  path.includes('/issue990-duplicate-diagnostics/') ||
  path.includes('/issue976-readonly-template-index/') ||
  path.includes('/issue991-element-elaboration/') ||
  path.includes('/issue993-argument-inner-mismatch/') ||
  path.includes('/issue992-tuple-spread-union/') ||
  path.includes('/issue996-named-array-element/') ||
  path.includes('/issue1000-generic-arguments/') ||
  path.includes('/issue999-object-array-element/') ||
  path.includes('/issue1001-string-surface/') ||
  path.includes('/issue995-keyof-apparent/') ||
  path.includes('/issue1002-keyof-display/') ||
  path.includes('/issue975-union-member-order/') ||
  path.includes('/issue1005-bigint-literal/') ||
  path.includes('/issue1011-template-placeholder/') ||
  path.includes('/issue1012-signed-numeric-literal/') ||
  path.includes('/issue1014-number-literal-display/') ||
  path.includes('/issue1015-numeric-property-names/') ||
  path.includes('/issue1013-exported-const-types/') ||
  path.endsWith('/issue967-repeated-commonjs/tsconfig-clean.json') ||
  path.endsWith('/issue967-repeated-commonjs/tsconfig-overlap.json') ||
  path.endsWith('/issue967-repeated-commonjs/tsconfig.json')).sort()
if (configs.length === 0) {
  console.error('No admitted-JavaScript fixture configs found')
  process.exit(2)
}
for (const config of [
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-unscopables.json',
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-unscopables-no-checkjs.json',
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-unscopables-mutable.json',
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-unscopables-writes.json',
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-unscopables-missing.json',
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-jsdoc-union.json',
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-jsdoc-union-no-checkjs.json',
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-flat.json',
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-flat-no-checkjs.json',
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-flat-depth.json',
  'packages/ts_cli/testdata/issue846-readonly-array/tsconfig-flat-depth-no-checkjs.json',
  'packages/ts_cli/testdata/issue963-aggregate-type-parameter/tsconfig-infer-union.json',
  'packages/ts_cli/testdata/issue963-aggregate-type-parameter/tsconfig-infer-intersection.json',
  'packages/ts_cli/testdata/issue963-aggregate-type-parameter/tsconfig-iterable-union.json',
  'packages/ts_cli/testdata/issue963-aggregate-type-parameter/tsconfig-heritage-union.json',
  'packages/ts_cli/testdata/issue960-readonly-own-methods/tsconfig.json',
  'packages/ts_cli/testdata/issue960-readonly-own-methods/tsconfig-structural.json',
  'packages/ts_cli/testdata/issue960-readonly-own-methods/tsconfig-display.json',
  'packages/ts_cli/testdata/issue960-readonly-own-methods/tsconfig-arguments.json',
  'packages/ts_cli/testdata/issue972-generic-array-union-map/tsconfig.json',
  'packages/ts_cli/testdata/issue970-unique-symbol-keyof/tsconfig-arrays.json',
  'packages/ts_cli/testdata/issue970-unique-symbol-keyof/tsconfig-computed.json',
  'packages/ts_cli/testdata/issue970-unique-symbol-keyof/tsconfig-program.json',
  'packages/ts_cli/testdata/issue971-object-display/tsconfig.json',
  'packages/ts_cli/testdata/issue969-iterator-helpers/tsconfig.json',
  'packages/ts_cli/testdata/issue969-iterator-helpers/tsconfig-helpers.json',
  'packages/ts_cli/testdata/issue969-iterator-helpers/tsconfig-wrong.json',
  'packages/ts_cli/testdata/issue969-iterator-helpers/tsconfig-errors.json',
  'packages/ts_cli/testdata/issue969-iterator-helpers/tsconfig-guards.json',
  'packages/ts_cli/testdata/issue987-array-statics/tsconfig-statics.json',
  'packages/ts_cli/testdata/issue987-array-statics/tsconfig-targets.json',
  'packages/ts_cli/testdata/issue987-array-statics/tsconfig-explicit.json',
  'packages/ts_cli/testdata/issue988-entry-tuple/tsconfig.json',
  'packages/ts_cli/testdata/issue989-spread-array-literal/tsconfig.json',
  'packages/ts_cli/testdata/issue990-duplicate-diagnostics/tsconfig.json',
  'packages/ts_cli/testdata/issue976-readonly-template-index/tsconfig.json',
  'packages/ts_cli/testdata/issue991-element-elaboration/tsconfig.json',
  'packages/ts_cli/testdata/issue993-argument-inner-mismatch/tsconfig.json',
  'packages/ts_cli/testdata/issue992-tuple-spread-union/tsconfig.json',
  'packages/ts_cli/testdata/issue996-named-array-element/tsconfig.json',
  'packages/ts_cli/testdata/issue1000-generic-arguments/tsconfig.json',
  'packages/ts_cli/testdata/issue999-object-array-element/tsconfig.json',
  'packages/ts_cli/testdata/issue1001-string-surface/tsconfig.json',
  'packages/ts_cli/testdata/issue995-keyof-apparent/tsconfig.json',
  'packages/ts_cli/testdata/issue995-keyof-apparent/tsconfig-bigint.json',
  'packages/ts_cli/testdata/issue1002-keyof-display/tsconfig.json',
  'packages/ts_cli/testdata/issue975-union-member-order/tsconfig.json',
  'packages/ts_cli/testdata/issue1005-bigint-literal/tsconfig.json',
  'packages/ts_cli/testdata/issue1011-template-placeholder/tsconfig.json',
  'packages/ts_cli/testdata/issue1012-signed-numeric-literal/tsconfig.json',
  'packages/ts_cli/testdata/issue1014-number-literal-display/tsconfig.json',
  'packages/ts_cli/testdata/issue1015-numeric-property-names/tsconfig.json',
  'packages/ts_cli/testdata/issue1013-exported-const-types/tsconfig.json',
]) {
  if (!configs.includes(config)) {
    console.error(`Missing required oracle config: ${config}`)
    process.exit(2)
  }
}

const uncheckedCommonJsConfigs = [
  'function',
  'alias',
  'object',
  'class',
  'typed',
].map(name => `packages/ts_cli/testdata/issue965-commonjs-expando/tsconfig-${name}.json`)
uncheckedCommonJsConfigs.push('packages/ts_cli/testdata/issue967-repeated-commonjs/tsconfig-clean.json')
uncheckedCommonJsConfigs.push('packages/ts_cli/testdata/issue967-repeated-commonjs/tsconfig-overlap.json')
uncheckedCommonJsConfigs.push('packages/ts_cli/testdata/issue967-repeated-commonjs/tsconfig.json')
for (const name of ['', '-whole', '-named', '-tagged', '-chained']) {
  uncheckedCommonJsConfigs.push(`packages/ts_cli/testdata/issue966-commonjs-constructor/tsconfig${name}.json`)
}
for (const config of uncheckedCommonJsConfigs) {
  if (!configs.includes(config)) {
    console.error(`Missing unchecked CommonJS oracle config: ${config}`)
    process.exit(2)
  }
}
// Streams whose expected TEXT is native TypeScript 7.0.2's, because the only
// way they differ from TypeScript 5.7.3 is the order of a union's members.
// Exit status is still 5.7.3's: native 7 exits 1 where 5.7.3 and Home exit 2
// (#982). Every other stream stays on 5.7.3 in full — the two compilers print
// different text on 42 of these streams for reasons unrelated to order, mostly
// in the CommonJS and JSDoc families, so this list must stay short and each
// entry must say why it is here.
const nativeOrderConfigs = new Map([
  // `nested[0]` is `string[] | number[]` in native 7 under either setting;
  // 5.7.3 prints `number[] | string[]` only once lib checking is skipped.
  ['packages/ts_cli/testdata/issue846-readonly-array/tsconfig-flat-skip-lib-check.json', '#975'],
  ['packages/ts_cli/testdata/issue846-readonly-array/tsconfig-flat-no-checkjs-skip-lib-check.json', '#975'],
  // The fixture for the order itself: every row is a union whose written order
  // differs from the sorted one, so 5.7.3 and native 7 report the same
  // diagnostics and spell 47 of the 67 output lines differently.
  ['packages/ts_cli/testdata/issue975-union-member-order/tsconfig.json', '#975'],
])
const native7 = resolve(repo, 'bench/vs_tsgo/.tools/tsgo/node_modules/.bin/tsc')
if (nativeOrderConfigs.size > 0) {
  const nativeVersion = spawnSync(native7, ['--version'], { encoding: 'utf8' })
  if (nativeVersion.error || nativeVersion.status !== 0 || nativeVersion.stdout.trim() !== 'Version 7.0.2') {
    console.error('Expected native TypeScript 7.0.2 at bench/vs_tsgo/.tools/tsgo; got:', nativeVersion.error?.message ?? nativeVersion.stdout.trim())
    process.exit(2)
  }
  for (const config of nativeOrderConfigs.keys()) {
    if (!configs.includes(config)) {
      console.error(`Missing native-order oracle config: ${config}`)
      process.exit(2)
    }
  }
}

// `file(line,col): error TSxxxx` for every diagnostic, without its message.
// A native-order stream must report the same diagnostics in both compilers;
// only how a message spells a union may differ. That keeps the list from
// hiding a difference that is not about order.
function diagnosticHeaders(text) {
  return text.split('\n')
    .map(line => /^(\S.*\(\d+,\d+\): error TS\d+):/.exec(line)?.[1])
    .filter(Boolean)
    .join('\n')
}

const checks = [
  ...configs.map(config => ({ config, flags: [] })),
  ...uncheckedCommonJsConfigs.map(config => ({ config, flags: ['--checkJs', 'false'] })),
]

function run(command, config, flags) {
  return spawnSync(command, ['-p', config.split('/').at(-1), '--pretty', 'false', '--noEmit', ...flags], {
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
for (const { config, flags } of checks) {
  const label = `${config}${flags.length ? ` ${flags.join(' ')}` : ''}`
  let oracle = run('tsc', config, flags)
  const actual = run(home, config, flags)
  if (oracle.error || actual.error || oracle.signal || actual.signal) {
    mismatches++
    console.log(`ERROR ${label}: oracle=${oracle.error?.message ?? oracle.signal ?? 'ok'} home=${actual.error?.message ?? actual.signal ?? 'ok'}`)
    continue
  }
  if (nativeOrderConfigs.has(config)) {
    const order = run(native7, config, flags)
    if (order.error || order.signal) {
      mismatches++
      console.log(`ERROR ${label}: native 7=${order.error?.message ?? order.signal}`)
      continue
    }
    if (diagnosticHeaders(order.stdout) !== diagnosticHeaders(oracle.stdout)) {
      mismatches++
      console.log(`ERROR ${label}: listed as native-order, but TypeScript 5.7.3 and native 7.0.2 do not report the same diagnostics`)
      continue
    }
    oracle = { status: oracle.status, stdout: order.stdout, stderr: order.stderr }
  }
  const streams = ['stdout', 'stderr']
  const different = streams.filter(stream => oracle[stream] !== actual[stream])
  if (oracle.status !== actual.status || different.length) {
    mismatches++
    console.log(`DIFF ${label}: exit ${oracle.status}/${actual.status}; ${different.join(', ') || 'streams equal'}`)
    for (const stream of different) {
      const left = oracle[stream]
      const right = actual[stream]
      let index = 0
      while (index < left.length && index < right.length && left[index] === right[index]) index++
      console.log(`  ${stream} at ${index}: tsc=${excerpt(left, index)} home=${excerpt(right, index)}`)
    }
  }
}
console.log(`Compared ${checks.length} admitted-JavaScript oracle streams: ${checks.length - mismatches} exact matches, ${mismatches} mismatches.`)
process.exit(mismatches === 0 ? 0 : 1)
