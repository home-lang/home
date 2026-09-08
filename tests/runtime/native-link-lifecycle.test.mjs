import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-native-link-'))
const globalDirectory = join(directory, 'global')
const globalBins = join(directory, 'bin')
const env = {
  ...process.env,
  HOME_NATIVE_VM: '1',
  NO_COLOR: '1',
  BUN_INSTALL: join(directory, 'install'),
  BUN_INSTALL_GLOBAL_DIR: globalDirectory,
  BUN_INSTALL_BIN: globalBins,
  BUN_INSTALL_CACHE_DIR: join(directory, 'cache'),
}
function run(cwd, args, expected = 0) {
  const result = spawnSync(process.execPath, args, { cwd, env, encoding: 'utf8', timeout: 15000 })
  assert.equal(result.error, undefined)
  assert.equal(result.signal, null)
  assert.equal(result.status, expected, `${args.join(' ')}\n${result.stderr}\n${result.stdout}`)
  return result.stdout + result.stderr
}
function json(path) {
  return JSON.parse(readFileSync(path, 'utf8'))
}
function absent(path) {
  // existsSync follows symlinks and would incorrectly accept a dangling link.
  assert.throws(() => lstatSync(path), { code: 'ENOENT' })
}

try {
  for (const workspace of [false, true]) {
    for (const scoped of [false, true]) {
      const variant = `${workspace ? 'workspace' : 'standalone'}-${scoped ? 'scoped' : 'plain'}`
      const name = `${scoped ? '@home-link/' : ''}native-${variant}`
      const binName = `native-linked-${variant}`
      const root = join(directory, variant)
      const provider = workspace ? join(root, 'packages', 'provider') : join(root, 'provider')
      const consumer = join(root, 'consumer')
      mkdirSync(provider, { recursive: true })
      mkdirSync(consumer, { recursive: true })
      if (workspace) {
        writeFileSync(join(root, 'package.json'), JSON.stringify({ name: `root-${variant}`, workspaces: ['packages/*'] }))
      }
      writeFileSync(join(provider, 'package.json'), JSON.stringify({ name, version: '1.0.0', main: 'index.js', bin: { [binName]: 'cli.js' } }))
      writeFileSync(join(provider, 'index.js'), 'module.exports = "first"\n')
      writeFileSync(join(provider, 'cli.js'), '#!/usr/bin/env bun\nconsole.log("linked executable", process.argv.slice(2).join(" "))\n', { mode: 0o755 })
      writeFileSync(join(consumer, 'package.json'), JSON.stringify({ name: `consumer-${variant}` }))
      writeFileSync(join(consumer, 'bunfig.toml'), '[install]\nlinker = "hoisted"\n')

      const registration = run(provider, ['link'])
      assert.ok(registration.includes(`Registered "${name}"`), registration)
      const globalPackage = join(globalDirectory, 'node_modules', name)
      assert.equal(realpathSync(globalPackage), realpathSync(provider))
      assert.equal(realpathSync(join(globalBins, binName)), realpathSync(join(provider, 'cli.js')))
      assert.match(run(provider, ['run', join(globalBins, binName), 'global']), /linked executable global/)
      run(provider, ['--silent', 'link'])
      assert.equal(realpathSync(globalPackage), realpathSync(provider))

      run(consumer, ['link', name, '--save'])
      assert.equal(json(join(consumer, 'package.json')).dependencies[name], `link:${name}`)
      assert.equal(json(join(consumer, 'node_modules', name, 'package.json')).version, '1.0.0')
      assert.equal(realpathSync(join(consumer, 'node_modules', name)), realpathSync(provider))
      assert.equal(realpathSync(join(consumer, 'node_modules', '.bin', binName)), realpathSync(join(provider, 'cli.js')))
      assert.match(run(consumer, ['run', join(consumer, 'node_modules', '.bin', binName), 'local']), /linked executable local/)
      writeFileSync(join(provider, 'index.js'), 'module.exports = "changed through link"\n')
      assert.match(readFileSync(join(consumer, 'node_modules', name, 'index.js'), 'utf8'), /changed through link/)
      run(consumer, ['install', '--frozen-lockfile'])
      run(consumer, ['remove', name])
      assert.equal(json(join(consumer, 'package.json')).dependencies?.[name], undefined)
      absent(join(consumer, 'node_modules', name))
      absent(join(consumer, 'node_modules', '.bin', binName))
      assert.equal(realpathSync(globalPackage), realpathSync(provider))

      assert.match(run(provider, ['unlink']), /unlinked package/)
      absent(globalPackage)
      absent(join(globalBins, binName))
      assert.ok(existsSync(join(provider, 'package.json')), 'unlink must preserve the source package')
      assert.match(run(provider, ['unlink']), /not globally linked/)

      // Unregistering a package must not erase an unrelated physical install.
      mkdirSync(globalPackage, { recursive: true })
      writeFileSync(join(globalPackage, 'sentinel'), 'physical package')
      run(provider, ['unlink'])
      assert.equal(readFileSync(join(globalPackage, 'sentinel'), 'utf8'), 'physical package')
    }
  }

  // Cover every supported bin declaration, including directory iteration on
  // unregister. The lifecycle matrix above uses the single named-bin form.
  for (const form of ['file', 'map', 'directory']) {
    const name = `native-bin-${form}`
    const provider = join(directory, name)
    mkdirSync(join(provider, 'commands', 'nested'), { recursive: true })
    const packageJson = { name, version: '1.0.0' }
    const bins = form === 'file'
      ? { [name]: 'cli.js' }
      : { [`${name}-one`]: 'commands/one', [`${name}-two`]: 'commands/two' }
    if (form === 'directory') {
      packageJson.directories = { bin: 'commands' }
      delete bins[`${name}-one`]
      delete bins[`${name}-two`]
      bins.one = 'commands/one'
      bins.two = 'commands/two'
    } else {
      packageJson.bin = form === 'file' ? 'cli.js' : bins
    }
    writeFileSync(join(provider, 'package.json'), JSON.stringify(packageJson))
    for (const target of Object.values(bins)) {
      writeFileSync(join(provider, target), '#!/usr/bin/env bun\nconsole.log("bin declaration works")\n', { mode: 0o755 })
    }
    run(provider, ['link'])
    for (const [binName, target] of Object.entries(bins)) {
      assert.equal(realpathSync(join(globalBins, binName)), realpathSync(join(provider, target)))
      assert.match(run(provider, ['run', join(globalBins, binName)]), /bin declaration works/)
    }
    absent(join(globalBins, 'nested'))
    run(provider, ['unlink'])
    for (const binName of Object.keys(bins)) absent(join(globalBins, binName))
    assert.ok(existsSync(join(provider, 'package.json')))
  }
} finally {
  rmSync(directory, { recursive: true, force: true })
}
console.log('native link and unlink lifecycle regressions passed')
