export enum Action {
  BuildViews = 'build/views',
  BuildDocs = 'build/docs',
}
export enum Numeric {
  Zero,
  Five = 5,
  Six,
}
export enum Merged { First = 'first' }
export enum Merged { Second = 'second' }
export enum module { Value = 'shadowed module binding' }
namespace Group {
  export enum Nested { Value = 'namespace enum value' }
}
export { Action as Alias, Group }
export type OnlyType = { value: string }
export function ordinary() { return 'function export' }
export class Ordinary { value() { return 'class export' } }
