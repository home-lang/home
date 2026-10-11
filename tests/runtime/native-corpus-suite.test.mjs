import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, cpSync, existsSync, realpathSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, basename, relative } from 'node:path'

const temp = mkdtempSync(join(tmpdir(), 'home-native-suite-'))
const root = join(temp, 'packages/runtime/test/test')
const folder = join(root, 'js/bun/test/suite')
mkdirSync(folder, { recursive: true })
writeFileSync(join(root, 'BUN_TRACKED_FILES.txt'), ['a', 'b', 'c'].map(name => `js/bun/test/suite/${name}.test.js`).join('\n') + '\n')
const files = ['a', 'b', 'c'].map(name => join(folder, `${name}.test.js`))
const reports = []
const env = { ...process.env, NO_COLOR: '1', BUN_DEBUG_QUIET_LOGS: '1' }
for (const key of ['HOME_NATIVE_VM', 'HOME_CORPUS_FULL_VM', 'HOME_NATIVE_RUN', 'HOME_BUN_CORPUS_REPORT_DIR']) delete env[key]
function invoke(name, args, native = false) {
  const report = join(temp, `report-${name}`)
  const childEnv = { ...env, ...(native ? { HOME_NATIVE_VM: '1' } : { HOME_BUN_CORPUS_REPORT_DIR: report }) }
  if (!native) reports.push(report)
  const result = spawnSync(process.execPath, ['test', ...args], { cwd: temp, env: childEnv, encoding: 'utf8', timeout: 60000 })
  assert.equal(result.error, undefined)
  assert.equal(result.signal, null)
  return { ...result, report }
}
function journal(result) {
  const rows = readFileSync(join(result.report, 'events.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
  assert.equal(rows[0].purpose, 'suite')
  assert.equal(rows.filter(row => row.event === 'started').length, 1)
  const completed = rows.find(row => row.event === 'completed')
  assert.equal(completed.output_complete, true)
  assert.equal(completed.source_unchanged, true)
  assert.equal(rows.at(-1).event, 'finished')
  return rows
}
try {
  for (const [index, file] of files.entries()) writeFileSync(file, `import {test,expect} from 'bun:test'; test('case ${index}',()=>{console.log('SUITE_BODY:${index}');expect(true).toBe(true);});`)
  const collected = []
  for (let shard = 1; shard <= 2; shard++) {
    const args = [...files, `--shard=${shard}/2`]
    const direct = invoke(`direct-shard-${shard}`, args, true)
    const grouped = invoke(`shard-${shard}`, args)
    assert.equal(grouped.status, direct.status, grouped.stderr)
    const bodies = text => [...text.matchAll(/SUITE_BODY:(\d)/g)].map(match => match[1])
    assert.deepEqual(bodies(grouped.stdout), bodies(direct.stdout))
    collected.push(...bodies(grouped.stdout))
    journal(grouped)
  }
  assert.deepEqual(collected.sort(), ['0', '1', '2'])
  const directory = invoke('directory-shard', [folder, '--shard=1/2'])
  assert.equal(directory.status, 0, directory.stderr)
  journal(directory)

  writeFileSync(files[0], `import {test,expect} from 'bun:test'; test('first failure',()=>{console.log('BAIL:first');expect(false).toBe(true);}); test('later same file',()=>console.log('BAIL:later'));`)
  writeFileSync(files[1], `import {test} from 'bun:test'; test('later file',()=>console.log('BAIL:other'));`)
  const bail = invoke('bail', [files[0], files[1], '--bail=1'])
  assert.equal(bail.status, 1)
  assert(bail.stdout.includes('BAIL:first'))
  assert.doesNotMatch(bail.stdout, /BAIL:later|BAIL:other/)
  const bailRows = journal(bail)
  assert.equal(bailRows.find(row => row.event === 'completed').counts.failed, 1)
  assert.equal(bailRows.find(row => row.event === 'suite_plan').inputs.length, 2)

  writeFileSync(files[0], `import {test,expect,afterAll} from 'bun:test';
    globalThis.__homeSuiteShared = 'shared';
    let active=0,peak=0,started=0;const releases=[];
    async function run(){active++;peak=Math.max(peak,active);started++;
      if(started===2){for(const resolve of releases)resolve();}else await new Promise(resolve=>releases.push(resolve));active--;}
    test('first concurrent',run);test('second concurrent',run);afterAll(()=>expect(peak).toBe(2));`)
  writeFileSync(files[1], `import {test,expect} from 'bun:test';test('shared realm across files',()=>expect(globalThis.__homeSuiteShared).toBe('shared'));`)
  const concurrent = invoke('concurrent', [files[0], files[1], '--concurrent', '--max-concurrency=2'])
  assert.equal(concurrent.status, 0, concurrent.stderr)
  journal(concurrent)

  writeFileSync(join(folder, 'helper.js'), 'export function sum(a,b){return a+b;}')
  for (const file of files.slice(0, 2)) writeFileSync(file, `import {test,expect} from 'bun:test';import {sum} from './helper.js';test('measured helper',()=>expect(sum(2,3)).toBe(5));`)
  const coverageDir = join(temp, 'coverage-output')
  const coverage = invoke('coverage', [files[0], files[1], '--coverage', '--coverage-reporter=lcov', `--coverage-dir=${coverageDir}`])
  assert.equal(coverage.status, 0, coverage.stderr)
  assert(existsSync(join(coverageDir, 'lcov.info')))
  assert(readFileSync(join(coverageDir, 'lcov.info'), 'utf8').includes('helper.js'))
  journal(coverage)

  for (const [index, file] of files.entries()) writeFileSync(file, `import {test,expect} from 'bun:test';
    expect(globalThis.__homeIsolatedState).toBeUndefined();globalThis.__homeIsolatedState=${index};
    test('isolated ${index}',()=>expect(globalThis.__homeIsolatedState).toBe(${index}));`)
  const isolated = invoke('isolate', [...files, '--isolate'])
  assert.equal(isolated.status, 0, isolated.stderr)
  journal(isolated)
  const parallel = invoke('parallel', [...files, '--parallel=2'])
  assert.equal(parallel.status, 0, parallel.stderr)
  const parallelRows = journal(parallel)
  assert.equal(parallelRows.find(row => row.event === 'completed').counts.passed, 3)

  for (const [index, file] of files.entries()) writeFileSync(file, `import {test,expect} from 'bun:test';
    let attempt=0;test('keep retry ${index}',()=>expect(++attempt).toBe(2));
    test.skip('keep skip ${index}',()=>{});test.todo('keep todo ${index}');
    test('excluded ${index}',()=>{throw new Error('excluded body executed');});`)
  const parallelMixed = invoke('parallel-mixed', [...files, '--parallel=2', '--retry=1', '-t', '^keep'])
  assert.equal(parallelMixed.status, 0, parallelMixed.stderr)
  const mixedCounts = journal(parallelMixed).find(row => row.event === 'completed').counts
  for (const key of ['passed', 'skipped', 'todo', 'filtered', 'retry_attempts']) assert.equal(mixedCounts[key], 3, key)
  assert.equal(mixedCounts.failed, 0)

  for (const file of files) writeFileSync(file, `import {test,expect} from 'bun:test';import {sum} from './helper.js';test('parallel helper',()=>expect(sum(2,3)).toBe(5));`)
  const parallelCoverageDir = join(temp, 'parallel-coverage')
  const parallelCoverage = invoke('parallel-coverage', [...files, '--parallel=2', '--coverage', '--coverage-reporter=lcov', `--coverage-dir=${parallelCoverageDir}`])
  assert.equal(parallelCoverage.status, 0, parallelCoverage.stderr)
  assert(readFileSync(join(parallelCoverageDir, 'lcov.info'), 'utf8').includes('helper.js'))
  journal(parallelCoverage)

  writeFileSync(files[0], '// ordinary empty test module\n')
  for (const file of files.slice(1)) writeFileSync(file, `import {test} from 'bun:test';test('ordinary parallel case',()=>{});`)
  const emptyParallel = invoke('parallel-empty-file', [...files, '--parallel=2'])
  assert.equal(emptyParallel.status, 0, emptyParallel.stderr)
  assert.equal(journal(emptyParallel).find(row => row.event === 'completed').counts.passed, 2)

  for (const [index, file] of files.entries()) writeFileSync(file, `import {test} from 'bun:test'; test('order ${index}',()=>console.log('ORDER:${index}'));`)
  const args = [...files, '--randomize', '--seed=27']
  const direct = invoke('direct-order', args, true)
  const seeded = invoke('seeded', args)
  assert.equal(seeded.status, 0, seeded.stderr)
  const order = text => [...text.matchAll(/ORDER:(\d)/g)].map(match => match[1])
  assert.deepEqual(order(seeded.stdout), order(direct.stdout))
  journal(seeded)
  const publicReport = join(temp, 'public-report.xml')
  const publicJUnit = invoke('public-junit', [...files, '--reporter=junit', '--reporter-outfile', publicReport])
  assert.equal(publicJUnit.status, 0, publicJUnit.stderr)
  assert.equal((readFileSync(publicReport, 'utf8').match(/<testcase\s/g) || []).length, 3)
  journal(publicJUnit)
  const dots = invoke('public-dots', [...files, '--reporter=dots'])
  assert.equal(dots.status, 0, dots.stderr)
  journal(dots)
  const parallelPublicReport = join(temp, 'parallel-public.xml')
  const parallelPublic = invoke('parallel-public-junit', [...files, '--parallel=2', '--reporter=junit', '--reporter-outfile', parallelPublicReport])
  assert.equal(parallelPublic.status, 0, parallelPublic.stderr)
  assert.equal((readFileSync(parallelPublicReport, 'utf8').match(/<testcase\s/g) || []).length, 3)
  journal(parallelPublic)

  function git(args) {
    const result = spawnSync('/usr/bin/git', args, { cwd: temp, encoding: 'utf8' })
    assert.equal(result.status, 0, result.stderr)
    return result.stdout.trim()
  }
  git(['init', '-q'])
  git(['config', 'user.name', 'Home Suite Fixture'])
  git(['config', 'user.email', 'fixture@home.invalid'])
  for (const [index, file] of files.entries()) {
    const dependency = join(folder, `dependency${index}.js`)
    writeFileSync(dependency, `export const value=${index};`)
    writeFileSync(file, `import {test,expect} from 'bun:test';import {value} from './dependency${index}.js';test('changed ${index}',()=>{console.log('CHANGED:${index}');expect(value).toBeGreaterThanOrEqual(0);});`)
  }
  git(['add', 'packages'])
  git(['commit', '-qm', 'fixture: record dependency graph'])
  writeFileSync(join(folder, 'dependency1.js'), 'export const value=11;')
  const changedArgs = [...files, '--changed=HEAD']
  const changedDirect = invoke('direct-changed', changedArgs, true)
  const changed = invoke('changed', changedArgs)
  assert.equal(changed.status, changedDirect.status, changed.stderr)
  const changedBodies = text => [...text.matchAll(/CHANGED:(\d)/g)].map(match => match[1])
  assert.deepEqual(changedBodies(changed.stdout), ['1'])
  assert.deepEqual(changedBodies(changed.stdout), changedBodies(changedDirect.stdout))
  assert.equal(journal(changed).find(row => row.event === 'completed').counts.passed, 1)
  git(['add', 'packages'])
  git(['commit', '-qm', 'fixture: update dependency'])
  const clean = invoke('changed-clean', [...files, '--changed=HEAD'])
  assert.equal(clean.status, 0, clean.stderr)
  assert.doesNotMatch(clean.stdout, /CHANGED:/)
  assert.equal(journal(clean).find(row => row.event === 'completed').counts.passed, 0)

  const emptyPublicPath = join(temp, 'empty-changed-public.xml')
  const emptyPublic = invoke('changed-clean-public', [...files, '--changed=HEAD', '--reporter=junit', '--reporter-outfile', emptyPublicPath])
  assert.equal(emptyPublic.status, 0, emptyPublic.stderr)
  assert.equal(existsSync(emptyPublicPath), false)
  assert.equal(journal(emptyPublic).find(row => row.event === 'completed').counts.passed, 0)

  const callerConfig = join(temp, 'caller-config.toml')
  writeFileSync(join(temp, 'caller-setup.js'), 'globalThis.__homeContextFlag="caller";')
  writeFileSync(callerConfig, '[test]\npreload=["./caller-setup.js"]\n')
  for (const file of files) writeFileSync(file, `import {test,expect} from 'bun:test';test('caller config context',()=>{expect(process.cwd()).toBe(${JSON.stringify(realpathSync(temp))});expect(globalThis.__homeContextFlag).toBe('caller');});`)
  for (const flag of ['--config=./caller-config.toml', '-c=./caller-config.toml']) {
    const result = invoke('caller-config-' + flag[1], [...files, flag])
    assert.equal(result.status, 0, result.stderr)
    assert.equal(journal(result).find(row => row.event === 'completed').counts.passed, 3)
  }
  const cwdFolder = join(temp, 'explicit-cwd')
  mkdirSync(cwdFolder)
  writeFileSync(join(cwdFolder, 'cwd-setup.js'), 'globalThis.__homeContextFlag="cwd";')
  writeFileSync(join(cwdFolder, 'cwd-config.toml'), '[test]\npreload=["./cwd-setup.js"]\n')
  for (const file of files) writeFileSync(file, `import {test,expect} from 'bun:test';test('explicit cwd',()=>{expect(process.cwd()).toBe(${JSON.stringify(realpathSync(cwdFolder))});});`)
  const cwdOnly = invoke('explicit-relative-cwd', [...files, '--cwd', './explicit-cwd'])
  assert.equal(cwdOnly.status, 0, cwdOnly.stderr)
  journal(cwdOnly)
  for (const file of files) writeFileSync(file, `import {test,expect} from 'bun:test';test('cwd config',()=>{expect(process.cwd()).toBe(${JSON.stringify(realpathSync(cwdFolder))});expect(globalThis.__homeContextFlag).toBe('cwd');});`)
  const cwdConfig = invoke('explicit-cwd-config', [...files, '--cwd=./explicit-cwd', '--config=./cwd-config.toml'])
  assert.equal(cwdConfig.status, 0, cwdConfig.stderr)
  assert.equal(journal(cwdConfig).find(row => row.event === 'completed').counts.passed, 3)

  const relativeFiles = files.map(file => relative(cwdFolder, file))
  const relativeArgs = [...relativeFiles, '--cwd=./explicit-cwd', '--config=./cwd-config.toml']
  const relativeDirect = invoke('direct-cwd-relative-targets', relativeArgs, true)
  assert.equal(relativeDirect.status, 0, relativeDirect.stderr)
  const relativeCwd = invoke('cwd-relative-targets', relativeArgs)
  assert.equal(relativeCwd.status, 0, relativeCwd.stderr)
  assert.equal(journal(relativeCwd).find(row => row.event === 'completed').counts.passed, 3)
  const cwdLink = join(temp, 'cwd-link')
  symlinkSync(cwdFolder, cwdLink, 'dir')
  for (const file of files) writeFileSync(file, `import {test,expect} from 'bun:test';test('symlink cwd config',()=>{expect(process.cwd()).toBe(${JSON.stringify(join(realpathSync(temp), 'cwd-link'))});expect(globalThis.__homeContextFlag).toBe('cwd');});`)
  const symlinkArgs = [...relativeFiles, '--cwd=./cwd-link', '--config=./cwd-config.toml']
  const symlinkDirect = invoke('direct-cwd-symlink', symlinkArgs, true)
  assert.equal(symlinkDirect.status, 0, symlinkDirect.stderr)
  const symlinkCwd = invoke('cwd-symlink', symlinkArgs)
  assert.equal(symlinkCwd.status, 0, symlinkCwd.stderr)
  assert.equal(journal(symlinkCwd).find(row => row.event === 'completed').counts.passed, 3)
  const aliases = [files[0], './' + relative(temp, files[1]), relative(temp, files[2])]
  const aliasArgs = [...aliases, '--config=./caller-config.toml']
  for (const file of files) writeFileSync(file, `import {test,expect} from 'bun:test';test('canonical source alias',()=>expect(globalThis.__homeContextFlag).toBe('caller'));`)
  const aliasDirect = invoke('direct-root-aliases', aliasArgs, true)
  const aliasSuite = invoke('root-aliases', aliasArgs)
  assert.equal(aliasDirect.status, 0, aliasDirect.stderr)
  assert.equal(aliasSuite.status, aliasDirect.status, aliasSuite.stderr)
  const aliasRows = journal(aliasSuite)
  assert.equal(aliasRows.find(row => row.event === 'completed').counts.passed, 3)
  assert.equal(aliasRows.find(row => row.event === 'suite_plan').inputs.length, 3)
  const overlappingArgs = [folder, files[0], '--config=./caller-config.toml']
  const overlappingDirect = invoke('direct-overlap', overlappingArgs, true)
  const overlappingSuite = invoke('overlap', overlappingArgs)
  assert.equal(overlappingDirect.status, 0, overlappingDirect.stderr)
  assert.equal(overlappingSuite.status, overlappingDirect.status, overlappingSuite.stderr)
  const overlapRows = journal(overlappingSuite)
  assert.equal(overlapRows.find(row => row.event === 'completed').counts.passed, 3)
  assert.equal(overlapRows.find(row => row.event === 'suite_plan').inputs.length, 3)

  console.log('native corpus suite shard, global bail, concurrency, coverage, isolation, parallel provenance, reporter outputs, changed selection, caller config/cwd, canonical root aliases, overlapping targets, seeded order and single-invocation evidence passed')
} finally {
  if (process.env.HOME_CORPUS_SUITE_EVIDENCE_DIR) {
    mkdirSync(process.env.HOME_CORPUS_SUITE_EVIDENCE_DIR)
    for (const report of reports) {
      if (existsSync(report)) cpSync(report, join(process.env.HOME_CORPUS_SUITE_EVIDENCE_DIR, basename(report)), { recursive: true })
      else writeFileSync(join(process.env.HOME_CORPUS_SUITE_EVIDENCE_DIR, basename(report) + '.missing.json'), JSON.stringify({ report, missing: true }) + '\n')
    }
  }
  rmSync(temp, { recursive: true, force: true })
}
