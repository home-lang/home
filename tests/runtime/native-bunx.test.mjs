import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { gzipSync } from 'node:zlib'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-native-bunx-'))
const requests = []
let expectRegistryToken = false
let server
const children = new Set()
const env = {
  ...process.env, HOME_NATIVE_VM: '1', HOME_CORPUS_FULL_VM: '1', HOME_NATIVE_RUN: '0',
  NO_COLOR: '1', FORCE_COLOR: '0', BUN_TMPDIR: join(directory, 'tmp'),
  TMPDIR: join(directory, 'tmp'), TMP: join(directory, 'tmp'), TEMP: join(directory, 'tmp'),
  BUN_INSTALL_CACHE_DIR: join(directory, 'cache'), NO_PROXY: '127.0.0.1,localhost',
  XDG_CONFIG_HOME: join(directory, 'config'),
}
for (const name of ['tmp', 'cache', 'project', 'config']) mkdirSync(join(directory, name))
// Use synthetic credentials in an isolated config directory. The registry
// override below must never forward the unrelated registry's token.
const npmrc = join(directory, 'config', '.npmrc')
writeFileSync(npmrc, '//registry.npmjs.org/:_authToken=home-fixture-token\n')
const project = join(directory, 'project')
writeFileSync(join(project, 'package.json'), '{}')
const args = ['space value', '', '$HOME', '$(echo injected)', ';echo injected', '*', 'line\nbreak', '--flag']

function run(argv, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(options.binary || process.execPath, argv, {
      cwd: options.cwd || project, env: { ...env, ...options.env }, stdio: ['ignore', 'pipe', 'pipe'],
    })
    children.add(child)
    let stdout = ''
    let stderr = ''
    const timer = setTimeout(() => child.kill('SIGKILL'), 15000)
    child.stdout.on('data', chunk => { stdout += chunk })
    child.stderr.on('data', chunk => { stderr += chunk })
    child.once('error', error => { clearTimeout(timer); children.delete(child); reject(error) })
    child.once('close', (code, signal) => {
      clearTimeout(timer)
      children.delete(child)
      resolve({ code, signal, stdout, stderr })
    })
  })
}

function record(result, binary = process.execPath) {
  assert.equal(result.code, 0, result.stderr)
  assert.equal(result.signal, null)
  const value = JSON.parse(result.stdout)
  assert.equal(realpathSync(value.execPath), realpathSync(binary))
  assert.deepEqual(value.args, args)
  return value
}

// Build real npm tarballs locally; neither fixture creation nor installation
// needs an installed package manager or an external registry.
function tarball(files) {
  const chunks = []
  for (const [path, contents] of Object.entries(files)) {
    const body = Buffer.from(contents)
    const header = Buffer.alloc(512)
    header.write('package/' + path)
    for (const [offset, width, value] of [[100, 8, 0o755], [108, 8, 0], [116, 8, 0], [124, 12, body.length], [136, 12, 0]]) {
      header.write(value.toString(8).padStart(width - 1, '0') + '\0', offset)
    }
    header.fill(32, 148, 156)
    header[156] = 48
    header.write('ustar\0', 257)
    header.write('00', 263)
    const checksum = header.reduce((sum, byte) => sum + byte, 0)
    header.write(checksum.toString(8).padStart(6, '0') + '\0 ', 148)
    chunks.push(header, body, Buffer.alloc((512 - body.length % 512) % 512))
  }
  return gzipSync(Buffer.concat([...chunks, Buffer.alloc(1024)]))
}

try {
  const source = '#!/usr/bin/env node\nconsole.log(JSON.stringify({execPath:process.execPath,args:process.argv.slice(2),answer:require("native-bunx-dep"),version:require("./package.json").version}));\n'
  const packages = {}
  for (const [name, versions] of Object.entries({ 'native-bunx-fixture': ['1.0.0', '1.0.1'], 'native-bunx-dep': ['1.0.0'] })) {
    packages[name] = {}
    for (const version of versions) {
      const manifest = name === 'native-bunx-fixture'
        ? { name, version, bin: { 'native-cli': 'bin.cjs' }, dependencies: { 'native-bunx-dep': '1.0.0' } }
        : { name, version, main: 'index.cjs' }
      const bytes = tarball({
        'package.json': JSON.stringify(manifest),
        ...(name === 'native-bunx-fixture' ? { 'bin.cjs': source } : { 'index.cjs': 'module.exports=42;' }),
      })
      packages[name][version] = { manifest, bytes }
    }
  }
  server = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    fetch(request) {
      assert.equal(request.headers.get('authorization') === 'Bearer home-fixture-token', expectRegistryToken)
      assert.equal(request.headers.has('authorization'), expectRegistryToken)
      assert.equal(request.headers.get('npm-auth-type'), expectRegistryToken ? 'legacy' : null)
      const path = new URL(request.url).pathname
      requests.push(path)
      const [name, separator, archive] = path.slice(1).split('/')
      if (!packages[name]) return new Response('unknown package', { status: 404 })
      if (separator === '-' && archive) {
        const version = archive.slice(name.length + 1, -4)
        const entry = packages[name][version]
        return entry ? new Response(entry.bytes, { headers: { 'content-type': 'application/octet-stream' } }) : new Response('unknown version', { status: 404 })
      }
      const versions = {}
      for (const [version, { manifest, bytes }] of Object.entries(packages[name])) {
        versions[version] = {
          ...manifest,
          dist: { tarball: server.url + name + '/-/' + name + '-' + version + '.tgz', integrity: 'sha512-' + createHash('sha512').update(bytes).digest('base64') },
        }
      }
      return Response.json({ name, 'dist-tags': { latest: Object.keys(versions).at(-1) }, versions })
    },
  })
  env.npm_config_registry = String(server.url)

  const invalid = await run(['x', 'target_script%'])
  assert.equal(invalid.code, 1)
  assert.match(invalid.stderr, /unrecognised dependency format/)
  assert.equal(requests.length, 0)
  const missing = await run(['x', '--no-install', 'native-missing-bin'])
  assert.equal(missing.code, 1)
  assert.match(missing.stderr, /Could not find an existing 'native-missing-bin' binary/)
  assert.equal(requests.length, 0)

  const installed = record(await run(['x', '--bun', '--package', 'native-bunx-fixture@1.0.0', 'native-cli', ...args]))
  assert.equal(installed.answer, 42)
  assert.equal(installed.version, '1.0.0')
  assert.ok(requests.includes('/native-bunx-fixture'))
  assert.ok(requests.includes('/native-bunx-dep'))
  assert.ok(requests.some(path => path.endsWith('/native-bunx-fixture-1.0.0.tgz')))
  assert.ok(requests.some(path => path.endsWith('/native-bunx-dep-1.0.0.tgz')))
  const requestCount = requests.length
  const cached = record(await run(['x', '--bun', '--no-install', '--package=native-bunx-fixture@1.0.0', 'native-cli', ...args]))
  assert.equal(cached.answer, 42)
  assert.equal(requests.length, requestCount, 'cache hit unexpectedly contacted the registry')
  const leadingFlag = record(await run(['--bun', 'x', '--no-install', '--package=native-bunx-fixture@1.0.0', 'native-cli', ...args]))
  assert.equal(leadingFlag.answer, 42)
  assert.equal(requests.length, requestCount)

  // A copied bunx executable must re-enter its native add command rather
  // than recursively interpreting "add" as another package to execute.
  const alias = join(directory, process.platform === 'win32' ? 'bunx.exe' : 'bunx')
  copyFileSync(process.execPath, alias)
  chmodSync(alias, 0o755)
  const aliasResult = record(await run(['--bun', '-p', 'native-bunx-fixture@1.0.1', 'native-cli', ...args], { binary: alias }), alias)
  assert.equal(aliasResult.version, '1.0.1')
  assert.equal(aliasResult.answer, 42)

  if (process.platform !== 'win32') {
    const cacheRoot = join(env.BUN_TMPDIR, 'bunx-' + process.getuid() + '-native-unsafe@latest')
    mkdirSync(cacheRoot)
    chmodSync(cacheRoot, 0o777)
    const before = requests.length
    const unsafe = await run(['x', '--no-install', 'native-unsafe'])
    assert.equal(unsafe.code, 1)
    assert.match(unsafe.stderr, /refusing to use bunx cache directory/)
    assert.equal(unsafe.stdout, '')
    assert.equal(requests.length, before)
    rmSync(cacheRoot, { recursive: true })
    symlinkSync(project, cacheRoot)
    const redirected = await run(['x', '--no-install', 'native-unsafe'])
    assert.equal(redirected.code, 1)
    assert.match(redirected.stderr, /refusing to use bunx cache directory/)
    assert.equal(requests.length, before)
  }
  for (const [command, transport] of [['add', 'http'], ['install', 'https']]) {
    // Retain credentials for a matching HTTP origin, but drop them when an
    // environment override downgrades an HTTPS registry to HTTP.
    const host = new URL(server.url).host
    writeFileSync(npmrc, `registry=${transport}://${host}/\n//${host}/:_authToken=home-fixture-token\n`)
    expectRegistryToken = transport === 'http'
    const analyzedProject = join(directory, 'analyze-' + command)
    const analyzedCache = join(directory, 'analyze-cache-' + command)
    mkdirSync(analyzedProject)
    mkdirSync(analyzedCache)
    writeFileSync(join(analyzedProject, 'package.json'), '{}')
    writeFileSync(join(analyzedProject, 'entry.ts'), 'import "./local.ts";')
    writeFileSync(join(analyzedProject, 'local.ts'), 'export * from "native-bunx-dep"; import "node:fs"; import type { Shape } from "native-type-only"; export const value: Shape | undefined = undefined;')
    const before = requests.length
    const analyzed = await run([command, './entry.ts', '--analyze'], {
      cwd: analyzedProject, env: { BUN_INSTALL_CACHE_DIR: analyzedCache },
    })
    assert.equal(analyzed.code, 0, analyzed.stderr)
    assert.equal(analyzed.signal, null)
    const manifest = JSON.parse(readFileSync(join(analyzedProject, 'package.json'), 'utf8'))
    assert.deepEqual(Object.keys(manifest.dependencies), ['native-bunx-dep'])
    assert.ok(requests.slice(before).includes('/native-bunx-dep'))
    assert.ok(requests.slice(before).some(path => path.endsWith('/native-bunx-dep-1.0.0.tgz')))
    assert.ok(!requests.slice(before).some(path => path.includes('native-type-only') || path.includes('node:fs')))
    const loaded = await run(['-e', 'console.log(require("native-bunx-dep"))'], { cwd: analyzedProject })
    assert.equal(loaded.code, 0, loaded.stderr)
    assert.equal(loaded.stdout, '42\n')
  }
  // Runtime resolution has its own package-manager entry and must initialize
  // the HTTP worker even when no install command or fetch has run first.
  expectRegistryToken = false
  writeFileSync(npmrc, '//registry.npmjs.org/:_authToken=home-fixture-token\n')
  const runtimeProject = join(directory, 'runtime-install')
  const runtimeCache = join(directory, 'runtime-cache')
  mkdirSync(runtimeProject)
  mkdirSync(runtimeCache)
  const beforeRuntime = requests.length
  const runtimeInstalled = await run(['-e', 'console.log(require("native-bunx-dep")); try { require.resolve("native-missing-package"); process.exit(99); } catch (error) { if (error.code !== "MODULE_NOT_FOUND") throw error; }'], {
    cwd: runtimeProject, env: { BUN_INSTALL_CACHE_DIR: runtimeCache },
  })
  assert.equal(runtimeInstalled.code, 0, runtimeInstalled.stderr)
  assert.equal(runtimeInstalled.signal, null)
  assert.equal(runtimeInstalled.stdout, '42\n')
  assert.ok(requests.slice(beforeRuntime).includes('/native-bunx-dep'))
  assert.ok(requests.slice(beforeRuntime).some(path => path.endsWith('/native-bunx-dep-1.0.0.tgz')))
  assert.ok(requests.slice(beforeRuntime).includes('/native-missing-package'))
  console.log('native bunx execution, installation, and dependency analysis passed')
} finally {
  for (const child of children) child.kill('SIGKILL')
  server?.stop(true)
  rmSync(directory, { recursive: true, force: true })
}
