import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const source = readFileSync(fileURLToPath(new URL('./fixtures/init-existing-entry.ts', import.meta.url)), 'utf8')
const root = mkdtempSync(join(tmpdir(), 'home-init-existing-entry-'))
try {
  writeFileSync(join(root, 'existing-entry.ts'), source)
  writeFileSync(join(root, 'package.json'), JSON.stringify({
    name: 'existing-entry',
    private: true,
    devDependencies: { '@types/bun': 'latest' },
    peerDependencies: { typescript: '^5' },
  }))
  execFileSync(process.execPath, ['init', '-y'], {
    cwd: root,
    env: { ...process.env, BUN_AGENT_RULE_DISABLED: '1' },
    stdio: ['ignore', 'inherit', 'inherit'],
    timeout: 30_000,
  })
  assert.equal(readFileSync(join(root, 'existing-entry.ts'), 'utf8'), source)
  assert.equal(existsSync(join(root, 'index.ts')), false)
  const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
  assert.equal(pkg.module, undefined)
  assert.equal(pkg.main, undefined)
  console.log('init preserves the existing non-index entry without creating an index or entry manifest fields')
} finally {
  rmSync(root, { recursive: true, force: true })
}
