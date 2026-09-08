import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-native-patch-'))
const names = ['native-patch-fixture', '@native-patch/fixture']
const original = 'module.exports = "original package";\n'
const archives = new Map()
for (const name of names) {
  const bytes = await new Bun.Archive({
    'package/package.json': JSON.stringify({ name, version: '1.0.0', main: 'index.js' }),
    'package/index.js': original,
    'package/removed.txt': 'remove this in the patch\n',
  }, { compress: 'gzip' }).bytes()
  archives.set(name, { bytes, integrity: `sha512-${createHash('sha512').update(bytes).digest('base64')}` })
}
const requests = []
const server = Bun.serve({
  hostname: '127.0.0.1', port: 0,
  fetch(request) {
    const path = decodeURIComponent(new URL(request.url).pathname.slice(1))
    requests.push(path)
    const name = path.replace(/\.tgz$/, '')
    const archive = archives.get(name)
    if (!archive) return new Response('fixture not found', { status: 404 })
    if (path.endsWith('.tgz')) return new Response(archive.bytes)
    return Response.json({
      name, 'dist-tags': { latest: '1.0.0' },
      versions: { '1.0.0': { name, version: '1.0.0', dist: { tarball: `${server.url}${encodeURIComponent(name)}.tgz`, integrity: archive.integrity } } },
    })
  },
})
const env = { ...process.env, HOME_NATIVE_VM: '1', NO_COLOR: '1', BUN_INSTALL_CACHE_DIR: join(directory, 'cache') }
async function run(cwd, args) {
  const child = Bun.spawn([process.execPath, ...args], { cwd, env, stdout: 'pipe', stderr: 'pipe', stdin: 'ignore' })
  const timeout = setTimeout(() => child.kill('SIGKILL'), 15000)
  try {
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    assert.equal(code, 0, `${args.join(' ')}\n${stderr}\n${stdout}`)
    return stdout + stderr
  } finally {
    clearTimeout(timeout)
  }
}
function setup(cwd, name, linker) {
  mkdirSync(cwd, { recursive: true })
  writeFileSync(join(cwd, 'package.json'), JSON.stringify({ name: 'patch-consumer', dependencies: { [name]: '1.0.0' } }))
  writeFileSync(join(cwd, 'bunfig.toml'), `[install]\nregistry = ${JSON.stringify(server.url.href)}\nlinker = ${JSON.stringify(linker)}\n`)
}
try {
  for (const name of names) {
    for (const linker of ['hoisted', 'isolated']) {
      for (const command of ['patch', 'patch-commit']) {
        const variant = `${name.replaceAll('/', '-')}-${linker}-${command}`
        const cwd = join(directory, variant)
        const untouched = join(directory, `${variant}-untouched`)
        setup(cwd, name, linker)
        setup(untouched, name, linker)
        await run(cwd, ['install'])
        await run(untouched, ['install'])
        const preparation = await run(cwd, ['patch', `${name}@1.0.0`])
        const patchDirectory = preparation.match(/edit the following folder:\s*\n\s*(.+)/)?.[1]?.trim()
        assert.ok(patchDirectory, preparation)
        const modified = `module.exports = ${JSON.stringify(variant)};\n`
        writeFileSync(join(cwd, patchDirectory, 'index.js'), modified)
        writeFileSync(join(cwd, patchDirectory, 'added.txt'), `${variant}\n`)
        rmSync(join(cwd, patchDirectory, 'removed.txt'))
        const args = command === 'patch' ? ['patch', '--commit'] : ['patch-commit']
        args.push(patchDirectory, '--patches-dir', 'local-patches')
        await run(cwd, args)
        const manifest = JSON.parse(readFileSync(join(cwd, 'package.json'), 'utf8'))
        const patchFile = manifest.patchedDependencies[`${name}@1.0.0`]
        assert.match(patchFile, /^local-patches\//)
        const patchText = readFileSync(join(cwd, patchFile), 'utf8')
        assert.ok(patchText.includes(`+${modified.trim()}`), patchText)
        assert.ok(patchText.includes('-module.exports = "original package";'), patchText)
        assert.ok(patchText.includes('added.txt'), patchText)
        assert.ok(patchText.includes('removed.txt'), patchText)
        assert.equal(readFileSync(join(untouched, 'node_modules', name, 'index.js'), 'utf8'), original, 'preparing a patch must not mutate another install')
        const lock = readFileSync(join(cwd, 'bun.lock'))
        rmSync(join(cwd, 'node_modules'), { recursive: true, force: true })
        await run(cwd, ['install', '--frozen-lockfile'])
        assert.deepEqual(readFileSync(join(cwd, 'bun.lock')), lock)
        assert.equal(readFileSync(join(cwd, 'node_modules', name, 'index.js'), 'utf8'), modified)
        assert.equal(readFileSync(join(cwd, 'node_modules', name, 'added.txt'), 'utf8'), `${variant}\n`)
        assert.throws(() => readFileSync(join(cwd, 'node_modules', name, 'removed.txt')), { code: 'ENOENT' })
        rmSync(join(untouched, 'node_modules'), { recursive: true, force: true })
        await run(untouched, ['install', '--frozen-lockfile'])
        assert.equal(readFileSync(join(untouched, 'node_modules', name, 'index.js'), 'utf8'), original, 'cached original must remain unpatched')
      }
    }
  }
  for (const name of names) assert.ok(requests.includes(`${name}.tgz`), 'exercise real tarball downloads')
} finally {
  await server.stop(true)
  rmSync(directory, { recursive: true, force: true })
}
console.log('native patch lifecycle regressions passed')
