/** A genuine leading documentation comment. */
export function typed(value: number): number {
  return value + 1;
}
/* Ordinary comments must not copy earlier source declarations. */
export function after(value: number): number {
  return typed(value);
}
