// Source-level ownership guards only; these do not count as native runtime parity.
import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'

const source = readFileSync(new URL('../../packages/runtime/upstream/src/jsc/bindings/webcore/Worker.cpp', import.meta.url), 'utf8')

function section(start: string, end: string): string {
  const begin = source.indexOf(start)
  const finish = source.indexOf(end, begin + start.length)
  expect(begin).toBeGreaterThanOrEqual(0)
  expect(finish).toBeGreaterThan(begin)
  return source.slice(begin, finish).replace(/\/\/[^\n]*|\/\*[\s\S]*?\*\//g, '')
}

describe('Worker incoming-inbox shutdown source contracts (#465)', () => {
  test('late messages are rejected before append under the inbox lock', () => {
    const enqueue = section('void Worker::enqueueToWorker(', '\nvoid Worker::enqueueToParent(')
    expect(enqueue).toMatch(/Locker locker \{ m_toWorker\.lock \};\s*const auto state = m_state\.load\(\);\s*if \(state >= State::Closing\)\s*return;\s*m_toWorker\.queue\.append/)
    expect(enqueue).toContain('if (state != State::Running ||')
  })

  test('shutdown seals and extracts under locks, then destroys outside them', () => {
    const shutdown = section('bool Worker::dispatchExit(', '\nextern "C" void WebWorker__teardownJSCVM(')
    expect(shutdown).toMatch(/Deque<MessageWithMessagePorts> dropped;\s*\{\s*Locker pendingLocker \{ m_pendingTasksMutex \};\s*Locker inboxLocker \{ m_toWorker\.lock \};\s*m_state\.store\(State::Closing\);\s*dropped = std::exchange\(m_toWorker\.queue, \{\}\);\s*m_toWorker\.drainScheduled\.store\(false, std::memory_order_relaxed\);\s*\}\s*dropped\.clear\(\);/)
    expect(shutdown.indexOf('dropped.clear();')).toBeLessThan(shutdown.indexOf('return ScriptExecutionContext::postTaskTo('))
    expect(shutdown).not.toContain('m_toParent')
    expect(shutdown).not.toContain('m_pendingTasks.clear')
  })

  test('startup cannot reopen Closing and terminate remains a request', () => {
    const online = section('void Worker::dispatchOnline(', '\nstatic inline void workerScheduleInitialDrain(')
    expect(online).toMatch(/Locker lock\(m_pendingTasksMutex\);\s*if \(m_state\.load\(\) != State::Pending\)\s*return;\s*m_state\.store\(State::Running\);/)
    const terminate = section('void Worker::terminate()', '\nvoid Worker::setKeepAlive(')
    expect(terminate).toContain('m_terminateRequested.exchange(true)')
    expect(terminate).toContain('WebWorker__notifyNeedTermination(impl_)')
    expect(terminate).not.toContain('m_state.store')
  })

  test('actual linked baseline keeps the pre-enqueue ref hook and pointer ABI', () => {
    const shutdown = section('bool Worker::dispatchExit(', '\nextern "C" void WebWorker__teardownJSCVM(')
    expect(shutdown).toMatch(/ScriptExecutionContext::postTaskTo\(\s*m_parentContextId,\s*\[this\] \{ this->deref\(\); \},\s*\[exitCode, protectedThis = Ref \{ \*this \}]/)
    expect(shutdown).not.toContain('protectedThis->deref()')
    expect(source).toContain('Worker* worker, BunString* message, JSC::EncodedJSValue errorValue)')
    expect(source).toContain('WTF::String messageStr = message->transferToWTFString();')
    expect(source).toContain('WTF::Locker locker { moduleLoader->cellLock() };')
  })
})
