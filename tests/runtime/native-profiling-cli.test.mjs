import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const dir = mkdtempSync(join(tmpdir(), 'home-native-profiling-'))
const workload = `function profileWork(){let result=0;for(let i=0;i<1000;i++)result+=Math.sqrt(i);return result}const end=performance.now()+150;while(performance.now()<end)profileWork();console.log('done')`
function run(flags, code = workload) {
  const child = spawnSync(process.execPath, [...flags, '-e', code], { cwd: dir, encoding: 'utf8', timeout: 30000 })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  assert.equal(child.status, 0, child.stderr)
  return child
}
try {
  run(['--cpu-prof', '--cpu-prof-md', '--cpu-prof-name', 'sample', '--cpu-prof-dir', 'cpu/nested'])
  const cpu = JSON.parse(readFileSync(join(dir, 'cpu/nested/sample.cpuprofile'), 'utf8'))
  assert(cpu.nodes.length > 0)
  assert(cpu.samples.length > 0)
  assert.equal(cpu.samples.length, cpu.timeDeltas.length)
  assert(cpu.nodes.some(node => node.callFrame.functionName === 'profileWork'))
  const ids = new Set(cpu.nodes.map(node => node.id))
  assert(cpu.samples.every(id => ids.has(id)))
  assert.match(readFileSync(join(dir, 'cpu/nested/sample.md'), 'utf8'), /# CPU Profile/)
  const heap = run(['--heap-prof', '--heap-prof-name', 'sample.heapsnapshot', '--heap-prof-dir', 'heap/nested'], `globalThis.payload=Array.from({length:100},(_,i)=>({value:i}));process.exit(0)`)
  assert.match(heap.stderr, /Heap profile written to:/)
  const snapshot = JSON.parse(readFileSync(join(dir, 'heap/nested/sample.heapsnapshot'), 'utf8'))
  assert(snapshot.snapshot.node_count > 0)
  assert(snapshot.nodes.length > 0)
  assert(snapshot.edges.length > 0)
  assert(Array.isArray(snapshot.strings))
  run(['--heap-prof-md', '--heap-prof-name', 'sample.md', '--heap-prof-dir', 'heap'], `globalThis.payload=[1,2,3]`)
  assert.match(readFileSync(join(dir, 'heap/sample.md'), 'utf8'), /## GC Roots/)
  run(['--heap-prof'], `globalThis.payload=[1,2,3]`)
  assert(readdirSync(dir).some(name => /^Heap\.\d+\.\d+\.heapsnapshot$/.test(name)))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
