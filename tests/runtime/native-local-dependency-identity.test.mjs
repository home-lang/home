import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join, relative } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-local-dependency-identity-'))
const name = 'leading-flag-dependency'
const env = { ...process.env, HOME_NATIVE_VM: '1', NO_COLOR: '1' }
function run(cwd, args) {
  const result = spawnSync(process.execPath, args, { cwd, env, encoding: 'utf8', timeout: 15000 })
  assert.equal(result.error, undefined)
  assert.equal(result.signal, null)
  assert.equal(result.status, 0, `${args.join(' ')}\n${result.stderr}\n${result.stdout}`)
}
function check(project, group, value, version) {
  const raw = readFileSync(join(project, 'package.json'), 'utf8')
  // JSON.parse alone would silently discard duplicate keys. This fixture has
  // exactly one dependency with this name, across all dependency groups.
  assert.equal((raw.match(/"leading-flag-dependency"\s*:/g) || []).length, 1, raw)
  assert.equal(JSON.parse(raw)[group][name], value)
  assert.equal(JSON.parse(readFileSync(join(project, 'node_modules', name, 'package.json'), 'utf8')).version, version)
}

try {
  for (const group of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
    for (const form of ['file', 'relative', 'absolute']) {
      const scenario = join(directory, `${group}-${form}`)
      const project = join(scenario, 'project')
      const one = join(scenario, 'dependency-one')
      const two = join(scenario, 'dependency-two')
      const dev = join(scenario, 'dev-dependency')
      for (const path of [project, one, two, dev]) mkdirSync(path, { recursive: true })
      writeFileSync(join(one, 'package.json'), JSON.stringify({ name, version: '1.0.0' }))
      writeFileSync(join(two, 'package.json'), JSON.stringify({ name, version: '2.0.0' }))
      writeFileSync(join(dev, 'package.json'), JSON.stringify({ name: 'independent-dev-dependency', version: '1.0.0' }))
      const original = 'file:../dependency-one'
      writeFileSync(join(project, 'package.json'), JSON.stringify({ name: 'local-identity-root', [group]: { [name]: original } }))
      run(project, ['--only-missing', 'install', '--ignore-scripts'])
      check(project, group, original, '1.0.0')
      const target = form === 'absolute' ? two : `${form === 'file' ? 'file:' : ''}${relative(project, two)}`
      run(project, ['--only-missing', 'install', '--', target])
      check(project, group, original, '1.0.0')
      run(project, ['--only-missing', 'add', '-d', 'file:../dev-dependency'])
      check(project, group, original, '1.0.0')
      run(project, ['install', '--frozen-lockfile', '--ignore-scripts'])
      run(project, ['--silent', 'remove', name])
      const manifest = JSON.parse(readFileSync(join(project, 'package.json'), 'utf8'))
      for (const key of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
        assert.equal(manifest[key]?.[name], undefined)
      }
      assert.equal(manifest.devDependencies['independent-dev-dependency'], 'file:../dev-dependency')
    }
  }

  // Normal adds must still replace an existing local dependency, while new
  // local dependencies acquire their real name before either edit/install phase.
  const project = join(directory, 'dependencies-file', 'project')
  run(project, ['add', 'file:../dependency-one'])
  check(project, 'dependencies', 'file:../dependency-one', '1.0.0')
  run(project, ['add', 'file:../dependency-two'])
  check(project, 'dependencies', 'file:../dependency-two', '2.0.0')
  run(project, ['install', '--frozen-lockfile', '--ignore-scripts'])
} finally {
  rmSync(directory, { recursive: true, force: true })
}
console.log('native local dependency identity regressions passed')
