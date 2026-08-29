import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const env = { ...process.env, HOME_NATIVE_VM: '1', HOME_CORPUS_FULL_VM: '1', HOME_NATIVE_RUN: '0', NO_COLOR: '1' }
for (const key of ['npm_execpath', 'npm_node_execpath', 'npm_lifecycle_event', 'npm_package_name', 'npm_package_version', 'npm_package_json']) delete env[key]
const directory = mkdtempSync(join(tmpdir(), 'home-native-package-run-'))
function run(args, options = {}) {
  const result = spawnSync(process.execPath, args, { cwd: directory, env, encoding: 'utf8', timeout: 15000, ...options })
  assert.equal(result.error, undefined)
  return result
}
function success(args, options) {
  const result = run(args, options)
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.signal, null)
  return result
}
try {
  mkdirSync(join(directory, 'subdirectory'))
  mkdirSync(join(directory, 'cache'))
  env.BUN_TMPDIR = join(directory, 'cache')
  mkdirSync(join(directory, 'node_modules', '.bin'), { recursive: true })
  writeFileSync(join(directory, 'record.cjs'), `
    console.log(JSON.stringify({
      execPath: require('node:fs').realpathSync(process.execPath),
      args: process.argv.slice(2), cwd: process.cwd(),
      event: process.env.npm_lifecycle_event, script: process.env.npm_lifecycle_script,
      name: process.env.npm_package_name, version: process.env.npm_package_version,
      packageJson: process.env.npm_package_json, command: process.env.npm_command,
      npmExecPath: process.env.npm_execpath, node: process.env.NODE,
      nodeExists: require('node:fs').existsSync(process.env.NODE),
    }));
  `)
  const scripts = {
    precheck: 'node record.cjs pre', check: 'node record.cjs main', postcheck: 'node record.cjs post',
    native: 'bun record.cjs native', nested: 'npm run native',
    fail: 'exit 23', postfail: 'echo SHOULD_NOT_RUN',
    prefailpre: 'exit 17', failpre: 'echo SHOULD_NOT_RUN', postfailpre: 'echo SHOULD_NOT_RUN',
    failpost: 'echo main-ran', postfailpost: 'exit 19',
    echo: 'echo package-script', 'named.sh': 'echo named-shell-script',
    'collision.js': 'echo collision-script', 'script-only.js': 'echo fallback-script', 'unreadable.js': 'echo readable-script',
    copy: 'cat', empty: '',
  }
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ name: 'native-run-fixture', version: '2.3.4', scripts }))
  const args = ['space value', '', 'quote"value', "single'quote", '$HOME', '$(echo injected)', ';echo injected', '*', 'line\nbreak', '你好', '--flag']
  for (const prefix of [['--bun', 'run'], ['run', '--bun'], ['run', '--bun', '--shell=bun']]) {
    const result = success([...prefix, 'check', ...args])
    const records = result.stdout.trim().split('\n').map(line => JSON.parse(line))
    assert.equal(records.length, 3, result.stdout)
    assert.deepEqual(records.map(record => record.args), [['pre'], ['main', ...args], ['post']])
    assert.deepEqual(records.map(record => record.event), ['precheck', 'check', 'postcheck'])
    for (const record of records) {
      assert.equal(record.execPath, realpathSync(process.execPath))
      assert.equal(realpathSync(record.cwd), realpathSync(directory))
      assert.equal(record.name, 'native-run-fixture')
      assert.equal(record.version, '2.3.4')
      assert.equal(record.packageJson, join(record.cwd, 'package.json'))
      assert.equal(record.command, 'run-script')
      assert.equal(record.script, scripts[record.event])
      assert.equal(realpathSync(record.npmExecPath), realpathSync(process.execPath))
      assert.equal(record.nodeExists, true)
      assert.equal(realpathSync(record.node), realpathSync(process.execPath), 'node alias must outlive the CLI process')
      if (process.platform !== 'win32') assert.equal(lstatSync(dirname(dirname(record.node))).mode & 0o777, 0o700)
    }
  }
  for (const argv of [['native'], ['run', 'native'], ['run', 'nested']]) {
    const result = success(argv)
    const record = JSON.parse(result.stdout)
    assert.equal(record.execPath, realpathSync(process.execPath), result.stdout)
    assert.deepEqual(record.args, ['native'])
  }
  for (const argv of [
    ['--cwd', directory, '--bun', 'run', 'echo'],
    ['run', '--cwd', directory, 'echo'],
    ['--cwd', directory, 'echo'],
  ]) assert.equal(success(argv, { cwd: join(directory, 'subdirectory') }).stdout, 'package-script\n')
  assert.equal(success(['run', 'echo'], { cwd: join(directory, 'subdirectory') }).stdout, 'package-script\n')
  // Package lookup must pass its context to the VM, not apply relative --cwd
  // twice or discard module flags/configuration when the target is not a script.
  writeFileSync(join(directory, 'subdirectory', '.env'), 'HOME_MODULE_CONFIG_VALUE=module\n')
  writeFileSync(join(directory, 'subdirectory', 'entry.js'), 'console.log(JSON.stringify([process.env.HOME_MODULE_CONFIG_VALUE, process.argv.slice(2)]));')
  const configEnv = { ...env }
  delete configEnv.HOME_MODULE_CONFIG_VALUE
  for (const prefix of [[], ['run'], ['--bun', 'run']]) {
    const result = success([...prefix, '--cwd', 'subdirectory', '--no-env-file', 'entry.js', '--cwd', 'missing'], { env: configEnv })
    assert.equal(result.stdout, '[null,["--cwd","missing"]]\n')
  }
  assert.equal(success(['run', '--cwd', 'subdirectory', 'entry'], { env: configEnv }).stdout, '["module",[]]\n')
  const dotenvDirectory = join(directory, 'dotenv')
  mkdirSync(dotenvDirectory)
  const dotenvEnv = { ...env }
  for (const key of Object.keys(dotenvEnv)) if (key.startsWith('HOME_DOTENV_')) delete dotenvEnv[key]
  dotenvEnv.HOME_DOTENV_PROCESS = '$HOME_DOTENV_BASE'
  dotenvEnv.HOME_DOTENV_EMPTY = ''
  writeFileSync(join(dotenvDirectory, '.env'), String.raw`HOME_DOTENV_BASE=first
HOME_DOTENV_CHAIN=$HOME_DOTENV_BASE
HOME_DOTENV_BASE=last
HOME_DOTENV_FINAL=${'${HOME_DOTENV_CHAIN}'}:${'${HOME_DOTENV_MISSING:-fallback}'}
HOME_DOTENV_ESCAPED=\$HOME_DOTENV_BASE
HOME_DOTENV_PROCESS=ignored
HOME_DOTENV_EMPTY=ignored
HOME_DOTENV_INDIRECT=$HOME_DOTENV_PROCESS
HOME_DOTENV_ZERO=${'${HOME_DOTENV_EMPTY:-fallback}'}
HOME_DOTENV_QUOTED='single $HOME_DOTENV_BASE'
`)
  const dotenvKeys = ['BASE', 'CHAIN', 'FINAL', 'ESCAPED', 'PROCESS', 'EMPTY', 'INDIRECT', 'ZERO', 'QUOTED']
  const dotenvSource = 'console.log(JSON.stringify(' + JSON.stringify(dotenvKeys) + '.map(key => process.env["HOME_DOTENV_" + key])));'
  writeFileSync(join(dotenvDirectory, 'entry.js'), dotenvSource)
  const dotenvExpected = ['last', 'last', 'last:fallback', '$HOME_DOTENV_BASE', '$HOME_DOTENV_BASE', '', '$HOME_DOTENV_BASE', '', 'single last']
  for (const args of [['entry.js'], ['run', 'entry.js'], ['-e', dotenvSource]]) {
    assert.deepEqual(JSON.parse(success(args, { cwd: dotenvDirectory, env: dotenvEnv }).stdout), dotenvExpected)
  }
  writeFileSync(join(dotenvDirectory, 'first.env'), 'HOME_DOTENV_BASE=first-file\nHOME_DOTENV_CHAIN=$HOME_DOTENV_BASE\n')
  writeFileSync(join(dotenvDirectory, 'second.env'), 'HOME_DOTENV_BASE=second-first\nHOME_DOTENV_BASE=second-last\n')
  const explicit = ['--no-env-file', '--env-file', 'first.env', '--env-file', 'second.env', '--env-file', 'second.env']
  assert.deepEqual(JSON.parse(success([...explicit, '-e', dotenvSource], { cwd: dotenvDirectory, env: dotenvEnv }).stdout), [
    'second-last', 'second-last', null, null, '$HOME_DOTENV_BASE', '', null, null, null,
  ])
  // The shared Node parser replaces duplicate definitions but does not expand
  // dollars. Repeated calls must not retain its temporary input/arena storage.
  const parseEnvSource = `
    const assert = require('node:assert/strict');
    const { parseEnv } = require('node:util');
    const input = 'BASE=first\\nBASE=last\\nVALUE=$BASE\\nESCAPED=\\\\$BASE';
    for (let i = 0; i < 512; i++) {
      assert.deepEqual(parseEnv(input), { BASE: 'last', VALUE: '$BASE', ESCAPED: '\\\\$BASE' });
      if (i % 32 === 0) Bun.gc(true);
    }
    console.log('parse-env-complete');
  `
  assert.equal(success(['--no-env-file', '-e', parseEnvSource], { cwd: dotenvDirectory, env: dotenvEnv }).stdout, 'parse-env-complete\n')
  mkdirSync(join(directory, 'node_modules', 'native-condition'))
  writeFileSync(join(directory, 'node_modules', 'native-condition', 'package.json'), JSON.stringify({
    name: 'native-condition', exports: { 'native-config': './custom.js', default: './default.js' },
  }))
  writeFileSync(join(directory, 'node_modules', 'native-condition', 'custom.js'), 'module.exports = "custom";')
  writeFileSync(join(directory, 'node_modules', 'native-condition', 'default.js'), 'module.exports = "default";')
  writeFileSync(join(directory, 'conditions.js'), 'import value from "native-condition"; console.log(value, require("native-condition"));')
  assert.equal(success(['conditions.js']).stdout, 'default default\n')
  for (const flags of [['--conditions=native-config'], ['--conditions', 'unused', '--conditions', 'native-config'], ['--conditions=unused, native-config']]) {
    for (const prefix of [[], ['run']]) assert.equal(success([...prefix, ...flags, 'conditions.js']).stdout, 'custom custom\n')
  }
  writeFileSync(join(directory, 'loader.fixture'), 'const value: number = 42; console.log(value);')
  for (const prefix of [[], ['run']]) assert.equal(success([...prefix, '--loader', '.fixture:ts', './loader.fixture']).stdout, '42\n')
  writeFileSync(join(directory, 'echo'), 'console.log("file-entry");')
  assert.equal(success(['run', 'echo']).stdout, 'package-script\n')
  assert.equal(success(['run', './echo']).stdout, 'file-entry\n')
  assert.equal(success(['run', 'named.sh']).stdout, 'named-shell-script\n')
  writeFileSync(join(directory, 'extension-entry.ts'), 'console.log("resolved-ts");')
  for (const argv of [['extension-entry'], ['run', 'extension-entry'], ['run', '--if-present', 'extension-entry']]) {
    assert.equal(success(argv).stdout, 'resolved-ts\n')
  }
  mkdirSync(join(directory, 'without-entry'))
  writeFileSync(join(directory, 'without-entry', 'other.js'), 'console.log("not-an-entry");')
  writeFileSync(join(directory, 'data.json'), '{}')
  for (const prefix of [[], ['run'], ['--bun'], ['--bun', 'run']]) {
    for (const [target, kind] of [
      ['missing.js', 'Module'], ['./missing', 'Module'],
      [join(directory, 'missing-absolute'), 'Module'], ['./without-entry', 'Module'],
      ['missing.asset', 'File'], ['missing-script', 'Script'],
    ]) {
      const result = run([...prefix, target])
      assert.equal(result.status, 1)
      assert.equal(result.stdout, '')
      assert.equal(result.stderr, `error: ${kind} not found "${target}"\n`)
    }
    for (const target of ['data', 'data.json', './data']) {
      const result = run([...prefix, target])
      assert.equal(result.status, 1)
      assert.equal(result.stdout, '')
      assert.match(result.stderr, /^error: Cannot run ".*data\.json"\nnote: Bun cannot run json files directly\n$/)
    }
    assert.equal(success([...prefix, '--if-present', 'data.json']).stdout, '')
  }
  // File preference applies only to an existing fast-path file. A missing
  // .js entry may still name a package script before resolving a .ts sibling.
  writeFileSync(join(directory, 'collision.js'), 'console.log("collision-file");')
  writeFileSync(join(directory, 'script-only.ts'), 'console.log("resolved-script-file");')
  assert.equal(success(['collision.js']).stdout, 'collision-file\n')
  assert.equal(success(['run', 'collision.js']).stdout, 'collision-script\n')
  assert.equal(success(['script-only.js']).stdout, 'fallback-script\n')
  assert.equal(success(['./script-only.js']).stdout, 'resolved-script-file\n')
  if (process.platform !== 'win32' && process.getuid() !== 0) {
    const unreadable = join(directory, 'unreadable.js')
    writeFileSync(unreadable, 'console.log("unreadable-file");')
    chmodSync(unreadable, 0)
    try {
      assert.equal(success(['unreadable.js']).stdout, 'readable-script\n')
    }
    finally {
      chmodSync(unreadable, 0o600)
    }
  }
  writeFileSync(join(directory, 'runnable.json'), 'console.log("json-as-js");')
  for (const prefix of [[], ['run']]) {
    assert.equal(success([...prefix, '--loader', '.json:js', './runnable.json']).stdout, 'json-as-js\n')
  }
  writeFileSync(join(directory, 'runtime-error.js'), 'throw new Error("entry-runtime-error");')
  const runtimeFailure = run(['runtime-error.js'])
  assert.equal(runtimeFailure.status, 1)
  assert.match(runtimeFailure.stderr, /error: entry-runtime-error/)
  assert.match(runtimeFailure.stderr, /\nBun v[^\n]+\n$/)
  const debugDirectory = join(directory, 'debug-config')
  mkdirSync(debugDirectory)
  writeFileSync(join(debugDirectory, 'tsconfig.json'), JSON.stringify({ extends: './absent-tsconfig.json' }))
  writeFileSync(join(debugDirectory, 'bunfig.toml'), 'logLevel = "debug"\n')
  writeFileSync(join(debugDirectory, 'quiet.toml'), 'logLevel = "error"\n')
  writeFileSync(join(debugDirectory, 'index.js'), 'console.log("debug-entry");')
  const optionEntry = 'console.log(JSON.stringify({execPath:process.execPath,args:process.argv.slice(2)}));'
  writeFileSync(join(debugDirectory, 'option-entry.js'), optionEntry)
  writeFileSync(join(debugDirectory, '-option-entry.js'), optionEntry)
  function checkConfigEntry(argv, expectedArgs, quiet = false) {
    const result = success(argv, { cwd: debugDirectory })
    const record = JSON.parse(result.stdout)
    assert.equal(realpathSync(record.execPath), realpathSync(process.execPath))
    assert.deepEqual(record.args, expectedArgs)
    if (quiet) assert.equal(result.stderr, '')
    else assert.match(result.stderr, /ENOENT loading tsconfig\.json extends/, JSON.stringify(argv))
  }
  for (const prefix of [[], ['run']]) {
    const debug = success([...prefix, '--config=' + join(debugDirectory, 'bunfig.toml'), './index.js'], { cwd: debugDirectory })
    assert.equal(debug.stdout, 'debug-entry\n')
    assert.match(debug.stderr, /ENOENT loading tsconfig\.json extends/)
    const quiet = success([...prefix, '--config=' + join(debugDirectory, 'quiet.toml'), './index.js'], { cwd: debugDirectory })
    assert.equal(quiet.stdout, 'debug-entry\n')
    assert.equal(quiet.stderr, '')
    // Optional config values never consume a separate script token. Only
    // the long attached form selects quiet.toml in the pinned parser.
    for (const flag of ['--config', '-c', '-c=quiet.toml']) {
      checkConfigEntry([...prefix, flag, './option-entry.js', './index.js', ...args], ['./index.js', ...args])
    }
    checkConfigEntry([...prefix, '--config=quiet.toml', './option-entry.js', ...args], args, true)
    checkConfigEntry([...prefix, '--config', './option-entry.js', '-e', 'throw 1'], ['-e', 'throw 1'])
    checkConfigEntry([...prefix, '--config', '--', '-option-entry.js', '--config', 'tail'], ['--config', 'tail'])
    checkConfigEntry([...prefix, '--', '-option-entry.js', './index.js'], ['./index.js'], prefix.length > 0)
    checkConfigEntry([...prefix, './option-entry.js', '--config', 'quiet.toml', '--', '-c'], ['--config', 'quiet.toml', '--', '-c'], prefix.length > 0)
    const separateConfig = run([...prefix, '--config', 'quiet.toml', './option-entry.js'], { cwd: debugDirectory })
    assert.equal(separateConfig.status, 1)
    assert.equal(separateConfig.stdout, '')
  }
  checkConfigEntry(['--config', 'run', './option-entry.js', ...args], args)
  assert.equal(success(['--config', '-e', 'console.log("config-inline")'], { cwd: debugDirectory }).stdout, 'config-inline\n')
  const configHelp = success(['--config'], { cwd: debugDirectory })
  assert.match(configHelp.stdout, /Usage:/)
  assert.doesNotMatch(configHelp.stderr, /Unknown command/)
  // Resolving a non-runnable data file does not suppress a valid CLI binary.
  if (process.platform !== 'win32') {
    const binary = join(directory, 'node_modules', '.bin', 'data')
    writeFileSync(binary, '#!/bin/sh\necho data-binary\n')
    chmodSync(binary, 0o755)
    for (const prefix of [[], ['run']]) assert.equal(success([...prefix, 'data']).stdout, 'data-binary\n')
  }
  assert.equal(success(['run', '--silent', 'echo']).stderr, '')
  for (const [script, code, stdout] of [['fail', 23, ''], ['failpre', 17, ''], ['failpost', 19, 'main-ran\n']]) {
    const result = run(['run', script])
    assert.equal(result.status, code, result.stderr)
    assert.equal(result.stdout, stdout)
    assert.doesNotMatch(result.stdout + result.stderr, /SHOULD_NOT_RUN/)
  }
  for (const name of ['missing', 'empty']) {
    assert.equal(run(['run', name]).status, 1)
    const result = success(['run', '--if-present', name])
    assert.equal(result.stdout + result.stderr, '')
  }
  if (process.platform !== 'win32') {
    const bin = join(directory, 'node_modules', '.bin')
    for (const shell of ['bash', 'sh', 'zsh']) {
      const path = join(bin, shell)
      writeFileSync(path, '#!/bin/sh\necho WRONG_SHELL\n')
      chmodSync(path, 0o755)
    }
    assert.equal(success(['run', '--shell=system', 'echo']).stdout, 'package-script\n')
    const input = 'native-stdin\n'.repeat(10000)
    for (const shell of ['bun', 'system']) {
      assert.equal(success(['run', `--shell=${shell}`, 'copy'], { input, maxBuffer: 1024 * 1024 }).stdout, input)
    }
    const copy = join(bin, 'native-copy')
    writeFileSync(copy, '#!/bin/sh\ncat\n')
    chmodSync(copy, 0o755)
    assert.equal(success(['run', 'native-copy'], { input, maxBuffer: 1024 * 1024 }).stdout, input)
    assert.equal(success(['native-copy'], { input, maxBuffer: 1024 * 1024 }).stdout, input)
    const handshake = join(bin, 'native-handshake')
    writeFileSync(handshake, '#!/bin/sh\nprintf "ready\\n"\nIFS= read -r line || exit 91\nprintf "%s\\n" "$line"\n')
    chmodSync(handshake, 0o755)
    const live = Bun.spawn([process.execPath, 'run', 'native-handshake'], {
      cwd: directory, env, stdin: 'pipe', stdout: 'pipe', stderr: 'pipe',
    })
    const timer = setTimeout(() => live.kill(), 5000)
    try {
      const reader = live.stdout.getReader()
      const first = await reader.read()
      assert.equal(new TextDecoder().decode(first.value), 'ready\n', 'inherited output was buffered until exit')
      live.stdin.write('interactive-input\n')
      await live.stdin.flush()
      live.stdin.end()
      let tail = ''
      while (true) {
        const next = await reader.read()
        if (next.done) break
        tail += new TextDecoder().decode(next.value)
      }
      assert.equal(tail, 'interactive-input\n')
      assert.equal(await live.exited, 0, await live.stderr.text())
    } finally {
      clearTimeout(timer)
      live.kill()
      await live.exited
    }
    const kill = join(bin, 'native-signal')
    writeFileSync(kill, '#!/bin/sh\nkill -KILL $$\n')
    chmodSync(kill, 0o755)
    const killed = run(['run', 'native-signal'])
    assert.equal(killed.status, null)
    assert.equal(killed.signal, 'SIGKILL')
    const local = join(bin, 'native-record')
    writeFileSync(local, '#!/usr/bin/env node\n' + `console.log(require('node:fs').realpathSync(process.execPath));\n`)
    chmodSync(local, 0o755)
    assert.equal(success(['--bun', 'run', 'native-record']).stdout.trim(), realpathSync(process.execPath))
    const record = JSON.parse(success(['run', '--bun', 'native']).stdout)
    const cache = dirname(dirname(record.node))
    assert.ok(realpathSync(cache).startsWith(realpathSync(env.BUN_TMPDIR) + '/'))
    chmodSync(cache, 0o777)
    try {
      const rejected = run(['run', '--bun', 'native'])
      assert.equal(rejected.status, 1)
      assert.equal(rejected.stderr, 'error: UnsafeNodeShimDirectory\n')
      assert.equal(rejected.stdout, '')
    } finally {
      chmodSync(cache, 0o700)
    }
    rmSync(record.node)
    symlinkSync('/usr/bin/false', record.node)
    try {
      const rejected = run(['run', '--bun', 'native'])
      assert.equal(rejected.status, 1)
      assert.equal(rejected.stderr, 'error: UnsafeNodeShimTarget\n')
      assert.equal(rejected.stdout, '')
    } finally {
      rmSync(record.node)
      symlinkSync(realpathSync(process.execPath), record.node)
    }
  }
  const workspace = join(directory, 'workspace-filter')
  mkdirSync(workspace)
  writeFileSync(join(workspace, 'package.json'), JSON.stringify({
    name: 'filter-root', workspaces: ['packages/*'], scripts: { record: 'echo ROOT-MUST-NOT-RUN' },
  }))
  writeFileSync(join(workspace, 'record.cjs'), 'console.log(JSON.stringify({execPath: process.execPath, cwd: process.cwd(), args: process.argv.slice(2)}));')
  writeFileSync(join(workspace, 'burst.cjs'), 'for (let i = 0; i < 20; i++) console.log("log_line");')
  for (const name of ['a', 'b']) {
    const packageDirectory = join(workspace, 'packages', name)
    mkdirSync(packageDirectory, { recursive: true })
    writeFileSync(join(packageDirectory, 'package.json'), JSON.stringify({
      name: 'pkg-' + name,
      scripts: { record: 'bun ../../record.cjs', interrupt: 'bun ../../hold.cjs', instant: 'printf instant', burst: 'bun ../../burst.cjs', ...(name === 'a' ? { partial: 'echo only-a' } : {}) },
    }))
  }
  for (const prefix of [
    ['--filter', 'pkg-*'], ['run', '--filter', 'pkg-*'],
    ['--workspaces'], ['run', '--workspaces'], ['--bun', 'run', '--filter', 'pkg-*'],
  ]) {
    const result = success([...prefix, 'record', ...args], { cwd: workspace })
    assert.equal(result.stderr, '')
    assert.doesNotMatch(result.stdout, /ROOT-MUST-NOT-RUN/)
    const records = result.stdout.split('\n').filter(line => /^pkg-[ab] record: \{/.test(line))
    assert.equal(records.length, 2, result.stdout)
    for (const line of records) {
      const name = line[4]
      const record = JSON.parse(line.slice('pkg-a record: '.length))
      assert.equal(realpathSync(record.execPath), realpathSync(process.execPath))
      assert.equal(realpathSync(record.cwd), realpathSync(join(workspace, 'packages', name)))
      assert.deepEqual(record.args, args)
      assert.match(result.stdout, new RegExp(`pkg-${name} record: Exited with code 0`))
    }
  }
  const noMatch = run(['run', '--filter', 'absent-package', 'record'], { cwd: workspace })
  assert.equal(noMatch.status, 1)
  assert.match(noMatch.stderr, /No packages matched the filter/)
  const optional = success(['run', '--filter', 'absent-package', '--if-present', 'record'], { cwd: workspace })
  assert.equal(optional.stdout + optional.stderr, '')
  assert.match(success(['run', '--workspaces', '--if-present', 'partial'], { cwd: workspace }).stdout, /pkg-a partial: only-a/)
  const missingWorkspaceScript = run(['run', '--workspaces', 'partial'], { cwd: workspace })
  assert.equal(missingWorkspaceScript.status, 1)
  assert.match(missingWorkspaceScript.stderr, /Missing 'partial' script/)
  if (process.platform !== 'win32') {
    // Exit may be reported before pipe readability. Preserve even a fast,
    // unterminated final chunk before printing the process completion line.
    for (let i = 0; i < 20; i++) {
      assert.equal(success(['run', '--filter', 'pkg-a', 'instant'], { cwd: workspace }).stdout,
        'pkg-a: instant\npkg-a instant: Exited with code 0\n')
    }
    const colorArgs = ['run', '--filter', 'pkg-a', '--elide-lines', '15', 'burst']
    const colored = success(colorArgs, { cwd: workspace, env: { ...env, FORCE_COLOR: '1', NO_COLOR: '1' } })
    assert.match(colored.stdout, /\[5 lines elided\]/)
    assert.match(colored.stdout, /\u001B\[/)
    const plain = success(colorArgs, { cwd: workspace, env: { ...env, FORCE_COLOR: '0', NO_COLOR: '1' } })
    assert.doesNotMatch(plain.stdout, /\u001B\[|lines elided/)
    assert.equal(plain.stdout.match(/log_line/g).length, 20)
    writeFileSync(join(workspace, 'hold.cjs'), `
      process.on('SIGINT', () => { console.log('FILTER_STOP'); process.exit(0); });
      console.log('FILTER_READY');
      setInterval(() => {}, 1000);
    `)
    const child = spawn(process.execPath, ['run', '--filter', 'pkg-a', 'interrupt'], {
      cwd: workspace, env, stdio: ['ignore', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''
    let readyTimer
    let exitTimer
    const closed = new Promise((resolve, reject) => {
      child.once('error', reject)
      child.once('close', (code, signal) => resolve({ code, signal }))
    })
    const ready = new Promise((resolve, reject) => {
      readyTimer = setTimeout(() => reject(new Error('filter child did not become ready')), 10000)
      child.stdout.on('data', chunk => {
        stdout += chunk
        if (stdout.includes('FILTER_READY')) {
          clearTimeout(readyTimer)
          resolve()
        }
      })
      child.once('error', reject)
      child.once('close', () => {
        if (!stdout.includes('FILTER_READY')) reject(new Error('filter exited before readiness: ' + stderr))
      })
    })
    child.stderr.on('data', chunk => { stderr += chunk })
    try {
      await ready
      assert.equal(child.kill('SIGINT'), true)
      exitTimer = setTimeout(() => child.kill('SIGKILL'), 10000)
      const result = await closed
      assert.deepEqual(result, { code: 0, signal: null }, stderr)
      assert.match(stdout, /FILTER_STOP/)
      assert.equal(stderr, '')
    }
    finally {
      clearTimeout(readyTimer)
      clearTimeout(exitTimer)
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
      await closed.catch(() => {})
    }
  }
  console.log('native package-script dispatch passed')
} finally {
  rmSync(directory, { recursive: true, force: true })
}
