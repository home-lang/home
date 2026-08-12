#!/usr/bin/env bun
/**
 * Build and deploy the documentation site to home-lang.org.
 *
 * The build is the reason this is a script rather than a plain
 * `bunx @stacksjs/ts-cloud deploy`. BunPress renders into a `.bunpress`
 * SUBDIRECTORY of `--outdir`, so pointing a site `root` at the parent ships an
 * EMPTY release and the box 404s while the deploy reports success. So build to
 * a scratch directory, flatten `.bunpress` into `dist/docs`, and assert a
 * non-zero page count before anything leaves this machine.
 *
 * (The package scripts call bare `bunpress`, which has no runnable bin on npm.
 * The engine these docs are written against is @stacksjs/bunpress.)
 *
 * The deploy itself is ordinary. `_submodules` is kept out of the
 * pre-deployment secret scan by `infrastructure.security.scan.exclude` in
 * cloud.config.ts, so no staging directory is needed.
 *
 * Usage:
 *   HCLOUD_TOKEN=… PORKBUN_API_KEY=… PORKBUN_SECRET_KEY=… bun scripts/deploy-docs.ts
 *   bun scripts/deploy-docs.ts --build-only
 *   bun scripts/deploy-docs.ts --dry-run
 */
import { cp, mkdir, rm } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const docsOut = join(repoRoot, 'dist', 'docs')
const buildDir = join(repoRoot, 'dist', '.docs-build')
const args = process.argv.slice(2)
const buildOnly = args.includes('--build-only')
const passthrough = args.filter((arg) => arg !== '--build-only')

async function run(cmd: string[], cwd: string): Promise<void> {
  const proc = Bun.spawn(cmd, { cwd, stdout: 'inherit', stderr: 'inherit', env: process.env })
  const code = await proc.exited
  if (code !== 0)
    throw new Error(`${cmd.join(' ')} exited with ${code}`)
}

// 1. Build into a scratch directory, then flatten BunPress's `.bunpress` output
// into the site root so `dist/docs` holds the pages themselves.
await rm(buildDir, { recursive: true, force: true })
await run(['bunx', '--bun', '@stacksjs/bunpress', 'build', '--dir', './docs', '--outdir', './dist/.docs-build'], repoRoot)

await rm(docsOut, { recursive: true, force: true })
await mkdir(dirname(docsOut), { recursive: true })
await cp(join(buildDir, '.bunpress'), docsOut, { recursive: true })
await rm(buildDir, { recursive: true, force: true })

const pageCount = (await Array.fromAsync(new Bun.Glob('**/*.html').scan({ cwd: docsOut }))).length
if (pageCount === 0)
  throw new Error(`build produced no pages in ${docsOut}`)
console.log(`Built ${pageCount} pages into dist/docs`)

if (buildOnly)
  process.exit(0)

// 2. Deploy. HOME_LANG_PREBUILT drops the config's `build` step so ts-cloud does
// not re-run this script from inside itself.
process.env.HOME_LANG_PREBUILT = '1'
await run(
  ['bunx', '--bun', '@stacksjs/ts-cloud@0.7.116', 'deploy', '--env', 'production', '--yes', ...passthrough],
  repoRoot,
)

console.log('\nDeployed. Verify from the box, since a laptop cannot always resolve the public name:')
console.log('  ssh root@178.105.248.188 \'curl -sI --resolve home-lang.org:443:127.0.0.1 https://home-lang.org/ | head -1\'')
