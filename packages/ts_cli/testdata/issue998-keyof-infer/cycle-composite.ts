declare function take<T>(key: keyof T): T;
function cycle<T extends U, U extends T>(key: keyof (T & { fixed: number })) {
  const result = take(key);
  const reveal: never = result;
  result.fixed;
  result.missing;
  return reveal;
}
void cycle;
