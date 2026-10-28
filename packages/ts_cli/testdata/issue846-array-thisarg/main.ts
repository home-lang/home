import { mutableValues, readonlyValues } from './owner.js'

const context = { tag: 1 }
readonlyValues.map(value => value + 1, context)
readonlyValues.forEach(value => void value, context)
readonlyValues.every(value => value > 0, context)
readonlyValues.some(value => value > 0, context)
readonlyValues.findIndex(value => value > 0, context)
readonlyValues.findLastIndex(value => value > 0, context)
mutableValues.map(value => value + 1, context)
mutableValues.forEach(value => void value, context)
mutableValues.every(value => value > 0, context)
mutableValues.some(value => value > 0, context)
mutableValues.findIndex(value => value > 0, context)
mutableValues.findLastIndex(value => value > 0, context)

const wrong: string = readonlyValues.map(value => value + 1, context)[0]
readonlyValues.some(value => value > 0, context, context)
void wrong
