import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join, relative } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-native-bin-owner-'))
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
function run(cwd, args) {
  const result = spawnSync(process.execPath, args, { cwd, env, encoding: 'utf8', timeout: 15000 })
  assert.equal(result.error, undefined)
  assert.equal(result.signal, null)
  assert.equal(result.status, 0, `${args.join(' ')}\n${result.stderr}\n${result.stdout}`)
  return result.stdout
}
function absent(path) {
  assert.throws(() => lstatSync(path), { code: 'ENOENT' })
}
try {
  for (const form of ['file', 'named', 'map', 'directory']) {
    const command = `owner-${form}`
    const providers = ['a', 'b'].map(owner => {
      const name = form === 'file' ? `@${owner}/${command}` : `${command}-${owner}`
      const cwd = join(directory, name)
      mkdirSync(join(cwd, 'commands'), { recursive: true })
      const bins = { [command]: `commands/${command}` }
      if (form === 'map' || form === 'directory') bins[`${command}-extra`] = `commands/${command}-extra`
      const manifest = { name, version: '1.0.0' }
      if (form === 'directory') manifest.directories = { bin: 'commands' }
      else manifest.bin = form === 'file' ? bins[command] : bins
      writeFileSync(join(cwd, 'package.json'), JSON.stringify(manifest))
      for (const target of Object.values(bins)) writeFileSync(join(cwd, target), `#!/usr/bin/env bun\nconsole.log("owner ${owner}")\n`, { mode: 0o755 })
      return { name, cwd, bins }
    })
    const [a, b] = providers
    run(a.cwd, ['link'])
    run(b.cwd, ['link'])
    run(a.cwd, ['unlink'])
    absent(join(globalDirectory, 'node_modules', a.name))
    assert.equal(realpathSync(join(globalDirectory, 'node_modules', b.name)), realpathSync(b.cwd))
    for (const [name, target] of Object.entries(b.bins)) {
      assert.equal(realpathSync(join(globalBins, name)), realpathSync(join(b.cwd, target)), `${form}: preserve current owner`)
      assert.match(run(b.cwd, ['run', join(globalBins, name)]), /owner b/)
    }
    run(b.cwd, ['unlink'])
    for (const name of Object.keys(b.bins)) absent(join(globalBins, name))

    // A physical replacement belongs to its writer, even under our bin name.
    run(a.cwd, ['link'])
    for (const name of Object.keys(a.bins)) {
      rmSync(join(globalBins, name))
      writeFileSync(join(globalBins, name), 'unrelated physical executable')
    }
    run(a.cwd, ['unlink'])
    for (const name of Object.keys(a.bins)) {
      assert.equal(readFileSync(join(globalBins, name), 'utf8'), 'unrelated physical executable')
      rmSync(join(globalBins, name))
    }

    // Compare the link itself: normalization must accept absolute links and
    // dot segments, and cleanup must work when a file target has disappeared.
    if (form !== 'directory') {
      run(a.cwd, ['link'])
      for (const [name, target] of Object.entries(a.bins)) {
        const bin = join(globalBins, name)
        const registeredTarget = join(globalDirectory, 'node_modules', a.name, target)
        rmSync(bin)
        const linkTarget = form === 'map' ? `./${relative(globalBins, registeredTarget)}` : registeredTarget
        symlinkSync(linkTarget, bin)
        rmSync(join(a.cwd, target))
      }
      run(a.cwd, ['unlink'])
      for (const name of Object.keys(a.bins)) absent(join(globalBins, name))
    }
    for (const provider of providers) assert.ok(lstatSync(join(provider.cwd, 'package.json')).isFile())
  }
} finally {
  rmSync(directory, { recursive: true, force: true })
}
console.log('native bin ownership regressions passed')
