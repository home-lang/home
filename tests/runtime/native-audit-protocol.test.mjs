import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-native-audit-'))
const definitions = [
  ['production-parent', '1.0.0', { bridge: '1.0.0' }],
  ['development-parent', '1.0.0', { bridge: '2.0.0' }],
  ['bridge', '1.0.0', { 'production-leaf': '1.0.0' }],
  ['bridge', '2.0.0', { 'development-leaf': '1.0.0' }],
  ['production-leaf', '1.0.0', {}],
  ['development-leaf', '1.0.0', {}],
  ['workspace-dev-only', '1.0.0', {}],
]
const packages = new Map()
for (const [name, version, dependencies] of definitions) {
  const bytes = await new Bun.Archive({
    'package/package.json': JSON.stringify({ name, version, dependencies }),
    'package/index.js': `module.exports = ${JSON.stringify(`${name}@${version}`)};`,
  }, { compress: 'gzip' }).bytes()
  packages.set(`${name}@${version}`, { name, version, dependencies, bytes, integrity: `sha512-${createHash('sha512').update(bytes).digest('base64')}` })
}
const audits = []
let response = {}
let status = 200
const server = Bun.serve({
  hostname: '127.0.0.1', port: 0,
  async fetch(request) {
    const path = decodeURIComponent(new URL(request.url).pathname)
    if (path === '/-/npm/v1/security/advisories/bulk') {
      const bytes = new Uint8Array(await request.arrayBuffer())
      const body = JSON.parse(new TextDecoder().decode(Bun.gunzipSync(bytes)))
      audits.push({ method: request.method, headers: Object.fromEntries(request.headers), body })
      return typeof response === 'string' ? new Response(response, { status }) : Response.json(response, { status })
    }
    if (path.endsWith('.tgz')) {
      const archive = packages.get(path.slice(1, -4))
      return archive ? new Response(archive.bytes) : new Response('missing fixture', { status: 404 })
    }
    const name = path.slice(1)
    const available = [...packages.values()].filter(pkg => pkg.name === name)
    return Response.json({
      name, 'dist-tags': { latest: available.at(-1)?.version },
      versions: Object.fromEntries(available.map(pkg => [pkg.version, { name, version: pkg.version, dependencies: pkg.dependencies, dist: { tarball: `${server.url}${encodeURIComponent(`${name}@${pkg.version}`)}.tgz`, integrity: pkg.integrity } }])),
    })
  },
})
const env = { ...process.env, HOME_NATIVE_VM: '1', NO_COLOR: '1', BUN_INSTALL_CACHE_DIR: join(directory, 'cache') }
async function run(args, expected = 0) {
  const child = Bun.spawn([process.execPath, ...args], { cwd: directory, env, stdout: 'pipe', stderr: 'pipe', stdin: 'ignore' })
  const timeout = setTimeout(() => child.kill('SIGKILL'), 15000)
  try {
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    assert.equal(code, expected, `${args.join(' ')}\n${stderr}\n${stdout}`)
    return { stdout, stderr }
  } finally {
    clearTimeout(timeout)
  }
}
function normalize(body) {
  return Object.fromEntries(Object.entries(body).sort().map(([name, versions]) => [name, [...versions].sort()]))
}
try {
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ name: 'audit-root', dependencies: { 'production-parent': '1.0.0' }, devDependencies: { 'development-parent': '1.0.0' } }))
  writeFileSync(join(directory, 'bunfig.toml'), `[install]\nregistry = ${JSON.stringify(server.url.href)}\nlinker = "hoisted"\n`)
  const authority = server.url.host
  writeFileSync(join(directory, '.npmrc'), `//${authority}/:_authToken=fixture-audit-token\n`)
  await run(['install'])
  let lock = readFileSync(join(directory, 'bun.lock'))
  assert.match((await run(['audit'])).stdout, /No vulnerabilities found/)
  assert.deepEqual(normalize(audits.at(-1).body), normalize({ 'production-parent': ['1.0.0'], 'development-parent': ['1.0.0'], bridge: ['1.0.0', '2.0.0'], 'production-leaf': ['1.0.0'], 'development-leaf': ['1.0.0'] }))
  await run(['--prod', 'audit'])
  console.log('production audit request', JSON.stringify(audits.at(-1).body))
  assert.deepEqual(normalize(audits.at(-1).body), normalize({ 'production-parent': ['1.0.0'], bridge: ['1.0.0'], 'production-leaf': ['1.0.0'] }), 'production traversal must identify resolved versions, not package names')
  // Both versions can also be production dependencies. Traversal must
  // visit each version's distinct children rather than suppressing one.
  const manifest = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'))
  manifest.dependencies['development-parent'] = '1.0.0'
  delete manifest.devDependencies
  writeFileSync(join(directory, 'package.json'), JSON.stringify(manifest))
  await run(['install'])
  lock = readFileSync(join(directory, 'bun.lock'))
  await run(['audit', '--prod'])
  const allProduction = normalize({ 'production-parent': ['1.0.0'], 'development-parent': ['1.0.0'], bridge: ['1.0.0', '2.0.0'], 'production-leaf': ['1.0.0'], 'development-leaf': ['1.0.0'] })
  assert.deepEqual(normalize(audits.at(-1).body), allProduction, 'visit both production versions and their children')

  // Workspace edges require the same dev filtering as the root package.
  manifest.workspaces = ['workspace']
  mkdirSync(join(directory, 'workspace'))
  writeFileSync(join(directory, 'workspace', 'package.json'), JSON.stringify({ name: 'audit-workspace', dependencies: { 'production-leaf': '1.0.0' }, devDependencies: { 'workspace-dev-only': '1.0.0' } }))
  writeFileSync(join(directory, 'package.json'), JSON.stringify(manifest))
  await run(['install'])
  lock = readFileSync(join(directory, 'bun.lock'))
  await run(['audit'])
  assert.deepEqual(audits.at(-1).body['workspace-dev-only'], ['1.0.0'])
  await run(['audit', '--prod'])
  assert.deepEqual(normalize(audits.at(-1).body), allProduction, 'exclude workspace dev-only edges')
  const advisory = { id: 700001, severity: 'high', title: 'Fixture advisory', url: 'https://example.invalid/GHSA-home-fixture', vulnerable_versions: '<2.0.0' }
  response = { bridge: [advisory] }
  assert.match((await run(['audit'], 1)).stdout, /Fixture advisory/)
  assert.deepEqual(JSON.parse((await run(['audit', '--json'], 1)).stdout), response)
  assert.doesNotMatch((await run(['audit', '--audit-level', 'critical'])).stdout, /Fixture advisory/)
  assert.doesNotMatch((await run(['audit', '--ignore', 'GHSA-home-fixture'])).stdout, /Fixture advisory/)
  for (const request of audits) {
    assert.equal(request.method, 'POST')
    assert.equal(request.headers['content-encoding'], 'gzip')
    assert.equal(request.headers['content-type'], 'application/json')
    assert.equal(request.headers.accept, 'application/json')
    assert.equal(request.headers.authorization, 'Bearer fixture-audit-token')
  }
  response = {}
  const auth = Buffer.from('fixture-user:fixture-password').toString('base64')
  writeFileSync(join(directory, '.npmrc'), `//${authority}/:_auth=${auth}\n`)
  await run(['audit'])
  assert.equal(audits.at(-1).headers.authorization, `Basic ${auth}`)
  response = '{invalid JSON'
  assert.match((await run(['audit', '--json'], 1)).stderr, /failed to parse json/)
  status = 503
  response = 'fixture unavailable'
  assert.match((await run(['audit'], 1)).stderr, /status 503/)
  assert.deepEqual(readFileSync(join(directory, 'bun.lock')), lock, 'auditing must not rewrite the lockfile')
} finally {
  await server.stop(true)
  rmSync(directory, { recursive: true, force: true })
}
console.log('native audit protocol and production graph regressions passed')
