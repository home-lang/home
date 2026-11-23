declare function take<T>(key: keyof T): T;
function cycle<A extends B, B extends C, C extends A>(key: keyof (A & { fixed: number })) {
  const result = take(key);
  const reveal: never = result;
  result.fixed;
  result.missing;
  const write: keyof A = "fixed";
  return [reveal, write];
}
void cycle;
