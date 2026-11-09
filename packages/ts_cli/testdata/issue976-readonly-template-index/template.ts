interface Attributes {
  [key: string]: string
  readonly [key: `data-${string}`]: string
  readonly [key: `locked_${string}`]: string
}
declare const attributes: Attributes
declare const anyKey: string
declare const dataKey: `data-${string}`

// The mutable string domain stays writable.
attributes.mutable = 'ok'
attributes['mutable'] = 'ok'
attributes[anyKey] = 'ok'
attributes[0] = 'ok'

// The readonly template domains do not.
attributes['data-fixed'] = 'bad'
attributes.locked_value = 'bad'
attributes[dataKey] = 'bad'

// A type alias carries the same signature.
type Aliased = {
  [key: string]: string
  readonly [key: `data-${string}`]: string
}
declare const aliased: Aliased
aliased.plain = 'ok'
aliased['data-x'] = 'bad'

// So does an interface that inherits it.
interface Inherited extends Attributes {
  own: string
}
declare const inherited: Inherited
inherited.own = 'ok'
inherited.plain = 'ok'
inherited['data-y'] = 'bad'

// A declared member takes precedence over a matching readonly pattern.
interface WithMember {
  'data-named': string
  readonly [key: `data-${string}`]: string
}
declare const withMember: WithMember
withMember['data-named'] = 'ok'
withMember['data-other'] = 'bad'

// Reading is always allowed.
const read: string = attributes['data-fixed']
const readTemplate: string = attributes[dataKey]
void read
void readTemplate
