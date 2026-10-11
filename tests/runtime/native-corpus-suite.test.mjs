import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, cpSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, basename } from 'node:path'

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

  for (const [index, file] of files.entries()) writeFileSync(file, `import {test} from 'bun:test'; test('order ${index}',()=>console.log('ORDER:${index}'));`)
  const args = [...files, '--randomize', '--seed=27']
  const direct = invoke('direct-order', args, true)
  const seeded = invoke('seeded', args)
  assert.equal(seeded.status, 0, seeded.stderr)
  const order = text => [...text.matchAll(/ORDER:(\d)/g)].map(match => match[1])
  assert.deepEqual(order(seeded.stdout), order(direct.stdout))
  journal(seeded)
  console.log('native corpus suite shard, global bail, concurrency, coverage, seeded order and single-invocation evidence passed')
} finally {
  if (process.env.HOME_CORPUS_SUITE_EVIDENCE_DIR) {
    mkdirSync(process.env.HOME_CORPUS_SUITE_EVIDENCE_DIR)
    for (const report of reports) cpSync(report, join(process.env.HOME_CORPUS_SUITE_EVIDENCE_DIR, basename(report)), { recursive: true })
  }
  rmSync(temp, { recursive: true, force: true })
}
