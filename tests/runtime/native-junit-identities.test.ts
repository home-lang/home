import { describe, expect, test } from 'bun:test'

describe('suite\u001b[35m\u0000\ufffe\uffff & < > "', () => {
  test('case\u001b[0m\u0001\u000b\u001f\ufffe\uffff', () => expect(1).toBe(1))
  test('tabs\tnewlines\nreturns\r remain exact', () => expect(2).toBe(2))
  test('literal &#27; and replacement \ufffd remain distinct', () => expect(3).toBe(3))
  test.skip('skip\u001b[0m', () => {})
  test.todo('todo\u0000')
})
