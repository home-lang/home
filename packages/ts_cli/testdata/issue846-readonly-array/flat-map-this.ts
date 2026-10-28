import { readonlyValues, values } from './owner.js'

const context = { offset: 2 }

const readonlyResult: number[] = readonlyValues.flatMap(function (value) {
  const wrong: string = this.offset
  void wrong
  return [value + this.offset]
}, context)

const mutableResult: number[] = values.flatMap(function (value) {
  const offset: number = this.offset
  return value + offset
}, context)

const noContext: number[] = readonlyValues.flatMap(value => [value + 1])
const defaultThis: number[] = readonlyValues.flatMap(function (value) {
  const missing: undefined = this
  void missing
  return [value]
})
const annotatedThis: number[] = readonlyValues.flatMap(function (this: { offset: number }, value) {
  return value + this.offset
})
const explicit: number[] = readonlyValues.flatMap<number, typeof context>(function (value) {
  return value + this.offset
}, context)

readonlyValues.flatMap<number, typeof context>(function (value) {
  return value + this.offset
}, { offset: 'bad' })

void [readonlyResult, mutableResult, noContext, defaultThis, annotatedThis, explicit]
