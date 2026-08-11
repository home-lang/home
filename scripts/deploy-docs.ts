#!/usr/bin/env bun
/**
 * Build and deploy the documentation site to home-lang.org.
 *
 * Why this is a script and not just `bunx @stacksjs/ts-cloud deploy`:
 * ts-cloud runs a secret scan over the whole working directory before it will
 * deploy, and its ignore list is hard-coded (.git, node_modules, dist, build,
 * vendor, pantry, ...). It has no entry for `_submodules`, so the vendored
 * TypeScript compiler test baselines under
 * `_submodules/typescript-go/testdata/baselines/` trip the "AWS Secret Key"
 * heuristic six times on the identifier `publicVarWithPrivateModulePropertyTypes`,
 * and the security policy blocks the deploy. Those are not secrets, and none of
 * that tree is shipped anyway.
 *
 * So the deploy runs from a staging directory holding exactly what is
 * published: the built docs plus the cloud config. The scanner sees the same
 * files the box does.
 *
 * Usage:
 *   HCLOUD_TOKEN=… PORKBUN_API_KEY=… PORKBUN_SECRET_KEY=… bun scripts/deploy-docs.ts
 *   bun scripts/deploy-docs.ts --dry-run
 */
import { cp, mkdir, rm } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const docsOut = join(repoRoot, 'dist', 'docs')
const stageDir = join(repoRoot, 'dist', '.deploy')
const args = process.argv.slice(2)
const buildOnly = args.includes('--build-only')
const passthrough = args.filter(arg => arg !== '--build-only')

async function run(cmd: string[], cwd: string): Promise<void> {
  const proc = Bun.spawn(cmd, { cwd, stdout: 'inherit', stderr: 'inherit', env: process.env })
  const code = await proc.exited
  if (code !== 0)
    throw new Error(`${cmd.join(' ')} exited with ${code}`)
}

// 1. Build. The package scripts call bare `bunpress`, which has no runnable bin
// on npm; the engine these docs are written against is @stacksjs/bunpress.
//
// It writes the rendered site into a `.bunpress` SUBDIRECTORY of --outdir, not
// into --outdir itself. Shipping the parent therefore ships an empty release,
// which is exactly what happened the first time. So build into a scratch dir
// and flatten `.bunpress` into `dist/docs`, leaving the site root a plain
// directory of real files with no dot-directory for the packager to skip.
const buildDir = join(repoRoot, 'dist', '.docs-build')
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

// 2. Stage exactly what ships. `dist/` is on the scanner's ignore list, so the
// nested dist/docs inside the staging directory is skipped there too, leaving
// cloud.config.ts as the only file scanned.
await rm(stageDir, { recursive: true, force: true })
await mkdir(join(stageDir, 'dist'), { recursive: true })
await cp(docsOut, join(stageDir, 'dist', 'docs'), { recursive: true })
await cp(join(repoRoot, 'cloud.config.ts'), join(stageDir, 'cloud.config.ts'))

// 3. Deploy. HOME_LANG_PREBUILT drops the config's `build` step: the site root
// in the staging directory is already populated, and `docs/` is not staged.
process.env.HOME_LANG_PREBUILT = '1'
await run(
  ['bunx', '--bun', '@stacksjs/ts-cloud@0.7.111', 'deploy', '--env', 'production', '--yes', ...passthrough],
  stageDir,
)

console.log('\nDeployed. Verify from the box, since a laptop cannot always resolve the public name:')
console.log('  ssh root@178.105.248.188 \'curl -sI --resolve home-lang.org:443:127.0.0.1 https://home-lang.org/ | head -1\'')
