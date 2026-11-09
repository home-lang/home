const wrap = (compiled: (...args: unknown[]) => string): ((...args: unknown[]) => string) => {
  return (...args: unknown[]) => String(compiled(...args))
}
const zero = (): (() => number) => { return () => 42 }
const nested = (): (((value: string) => string)) => value => value
const generic = (): (<T>(value: T) => T) => value => value
const curried = (): ((first: number) => (second: number) => number) => first => second => first + second
const expression = (): ((value: number) => number) => value => value + 1

if (wrap(value => String(value))('retained') !== 'retained'
  || zero()() !== 42
  || nested()('nested') !== 'nested'
  || generic()(73) !== 73
  || curried()(20)(22) !== 42
  || expression()(41) !== 42) {
  throw new Error('Parenthesized function return annotation changed execution')
}
console.log('OK Home parenthesized function return annotations')
