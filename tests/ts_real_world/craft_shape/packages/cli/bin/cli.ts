import process from 'node:process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { spawn } from 'node:child_process'

interface Answers {
  name: string
  template: 'minimal' | 'react'
}

function parseArgs(argv: readonly string[]): Answers {
  const name = argv.find(arg => !arg.startsWith('-')) ?? 'my-app'
  const template = argv.includes('--react') ? 'react' : 'minimal'
  return { name, template }
}

function scaffold(answers: Answers): string {
  const target = resolve(process.cwd(), answers.name)
  if (!existsSync(target))
    mkdirSync(target, { recursive: true })
  const manifest = { name: answers.name, private: true, scripts: { dev: 'craft dev' } }
  writeFileSync(join(target, 'package.json'), `${JSON.stringify(manifest, null, 2)}\n`)
  return target
}

async function install(cwd: string): Promise<number> {
  return await new Promise<number>((done, fail) => {
    const child = spawn('bun', ['install'], { cwd, stdio: 'inherit' })
    child.on('error', fail)
    child.on('exit', code => done(code ?? 1))
  })
}

const answers = parseArgs(process.argv.slice(2))
const target = scaffold(answers)
const readme = existsSync(join(target, 'README.md')) ? readFileSync(join(target, 'README.md'), 'utf8') : ''
const code = await install(target)
process.stdout.write(`created ${target} (${readme.length} bytes of docs)\n`)
process.exitCode = code
