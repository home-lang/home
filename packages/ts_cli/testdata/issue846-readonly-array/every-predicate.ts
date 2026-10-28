import { mixed, mutable } from './predicate-owner.js'

const isNumber = (value: number | string): value is number => typeof value === 'number'

if (mixed.every(isNumber)) {
  const good: readonly number[] = mixed
  const bad: string = mixed[0]
  void [good, bad]
}

if (mutable.every(isNumber)) {
  const good: number[] = mutable
  const bad: string = mutable[0]
  void [good, bad]
}

if (mixed.every((value): value is number => typeof value === 'number')) {
  const bad: string = mixed[0]
  void bad
}

if (mixed.every(value => value)) {
  const stillUnion: number = mixed[0]
  void stillUnion
}

const outside: number | string = mixed[0]
void outside
