import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-native-update-'))
const name = 'native-update-fixture'
const versions = ['1.0.0', '1.1.0', '1.2.0', '2.0.0']
const archives = new Map()
for (const version of versions) {
  const bytes = await new Bun.Archive({
    'package/package.json': JSON.stringify({ name, version, main: 'index.js' }),
    'package/index.js': `module.exports = ${JSON.stringify(version)};`,
  }, { compress: 'gzip' }).bytes()
  archives.set(version, { bytes, integrity: `sha512-${createHash('sha512').update(bytes).digest('base64')}` })
}
let published = 1
const requests = []
const server = Bun.serve({
  hostname: '127.0.0.1', port: 0,
  fetch(request) {
    const path = new URL(request.url).pathname
    requests.push(path)
    if (path === `/${name}`) {
      const available = versions.slice(0, published)
      return Response.json({
        name,
        'dist-tags': { latest: available.at(-1) },
        versions: Object.fromEntries(available.map(version => [version, {
          name, version,
          dist: { tarball: `${server.url}${version}.tgz`, integrity: archives.get(version).integrity },
        }])),
      }, { headers: { 'cache-control': 'max-age=0' } })
    }
    const archive = archives.get(path.slice(1).replace(/\.tgz$/, ''))
    return archive ? new Response(archive.bytes) : new Response('fixture not found', { status: 404 })
  },
})
const env = { ...process.env, HOME_NATIVE_VM: '1', NO_COLOR: '1', BUN_INSTALL_CACHE_DIR: join(directory, 'cache') }
async function run(args, input) {
  const child = Bun.spawn([process.execPath, ...args], {
    cwd: directory, env, stdout: 'pipe', stderr: 'pipe', stdin: input === undefined ? 'ignore' : new Blob([input]),
  })
  const timeout = setTimeout(() => child.kill('SIGKILL'), 15000)
  try {
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    assert.equal(code, 0, `${args.join(' ')}\n${stderr}\n${stdout}`)
    return stdout + stderr
  } finally {
    clearTimeout(timeout)
  }
}
function installed() {
  return JSON.parse(readFileSync(join(directory, 'node_modules', name, 'package.json'), 'utf8')).version
}
function requestedVersion() {
  return JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8')).dependencies[name]
}

try {
  writeFileSync(join(directory, 'bunfig.toml'), `[install]\nregistry = ${JSON.stringify(server.url.href)}\nlinker = "hoisted"\n`)
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ name: 'update-root', dependencies: { [name]: '^1.0.0' } }))
  await run(['install'])
  assert.equal(installed(), '1.0.0')
  published = 2
  const before = requests.length
  // Cache writes are optional background work and may not finish before a
  // command exits. Force guarantees fresh discovery whether a cache was saved
  // or not; an ordinary read cannot promise a particular persisted generation.
  const outdated = await run(['outdated', '--force'])
  assert.match(outdated, /native-update-fixture/)
  assert.match(outdated, /1\.0\.0/)
  assert.match(outdated, /1\.1\.0/)
  assert.ok(requests.slice(before).includes(`/${name}`), 'outdated must consult the registry')
  const declined = await run(['update', '--interactive'], 'n\n')
  if (process.platform !== 'win32') {
    assert.match(declined, /\x1b\[\?2026h[\s\S]*native-update-fixture[\s\S]*\x1b\[\?2026l/)
  }
  assert.equal(installed(), '1.0.0')
  assert.equal(requestedVersion(), '^1.0.0')
  await run(['update'])
  assert.equal(installed(), '1.1.0')
  assert.equal(requestedVersion(), '^1.1.0')
  published = 3
  await run(['update', '--interactive'], 'a\n')
  assert.equal(installed(), '1.2.0')
  assert.equal(requestedVersion(), '^1.2.0')
  published = 4
  await run(['--latest', 'update', name])
  assert.equal(installed(), '2.0.0')
  assert.equal(requestedVersion(), '^2.0.0')
  await run(['install', '--frozen-lockfile'])
  assert.ok(requests.includes('/1.0.0.tgz'))
  assert.ok(requests.includes('/1.1.0.tgz'))
  assert.ok(requests.includes('/1.2.0.tgz'))
  assert.ok(requests.includes('/2.0.0.tgz'))
} finally {
  await server.stop(true)
  rmSync(directory, { recursive: true, force: true })
}
console.log('native update and outdated regressions passed')
