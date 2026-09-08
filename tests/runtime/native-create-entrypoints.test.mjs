import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-create-entrypoints-'))
const env = { ...process.env, HOME_NATIVE_VM: '1', NO_COLOR: '1' }
function run(args, cwd = directory) {
  const result = spawnSync(process.execPath, args, { cwd, env, encoding: 'utf8', timeout: 10000 })
  assert.equal(result.error, undefined)
  assert.equal(result.signal, null)
  return result
}

try {
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ scripts: { dev: 'bun ./dev.mjs' } }))
  writeFileSync(join(directory, 'dev.mjs'), 'console.log(JSON.stringify({exe: process.execPath, args: process.argv.slice(2)}))')
  const dev = run(['dev', 'argument', '--flag'])
  assert.equal(dev.status, 0, dev.stderr)
  assert.deepEqual(JSON.parse(dev.stdout), { exe: process.execPath, args: ['argument', '--flag'] })

  writeFileSync(join(directory, 'dev.mjs'), 'console.error("native-dev-failure"); process.exit(17)')
  const failed = run(['dev'])
  assert.equal(failed.status, 17, failed.stderr)
  assert.match(failed.stderr, /native-dev-failure/)

  const template = join(directory, 'template')
  const destination = join(directory, 'created')
  mkdirSync(template)
  writeFileSync(join(template, 'package.json'), JSON.stringify({ name: 'local-create-clock', version: '1.0.0' }))
  writeFileSync(join(template, 'README.md'), 'native template copied\n')
  const started = performance.now()
  const created = run(['create', template, destination, '--no-install', '--no-git'])
  const wallMilliseconds = performance.now() - started
  assert.equal(created.status, 0, created.stderr)
  assert.equal(readFileSync(join(destination, 'README.md'), 'utf8'), 'native template copied\n')
  const output = (created.stdout + created.stderr).replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, '')
  const timing = output.match(/\[\s*(\d+(?:\.\d+)?)\s*(ms|s)\]\s*bun create/)
  assert.ok(timing, output)
  const milliseconds = Number(timing[1]) * (timing[2] === 's' ? 1000 : 1)
  assert.ok(milliseconds >= 0 && milliseconds <= wallMilliseconds + 100, output)
} finally {
  rmSync(directory, { recursive: true, force: true })
}
console.log('native create entrypoint regressions passed')
