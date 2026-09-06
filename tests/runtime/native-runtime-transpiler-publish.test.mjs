import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { getEventLoopStats } from 'bun:internal-for-testing'

const root = mkdtempSync(join(tmpdir(), 'home-runtime-transpiler-publish-'))
const moduleCount = 1_024

try {
  const entryPath = join(root, 'entry.ts')
  let entrySource = ''
  for (let index = 0; index < moduleCount; index += 1) {
    const modulePath = join(root, `module-${index}.ts`)
    writeFileSync(modulePath, `export default (${index} as number)\n`)
    entrySource += `import value${index} from './module-${index}.ts'\n`
  }
  entrySource += `export default [${Array.from({ length: moduleCount }, (_, index) => `value${index}`).join(',')}]\n`
  writeFileSync(entryPath, entrySource)

  const module = await import(pathToFileURL(entryPath).href)
  assert.deepEqual(
    module.default,
    Array.from({ length: moduleCount }, (_, index) => index),
  )
  assert.equal(getEventLoopStats().nativeWorkPoolJobs, 0)
} finally {
  rmSync(root, { recursive: true, force: true })
}

console.log('native runtime transpiler publish ownership passed')
