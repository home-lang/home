declare function take<T>(key: keyof T): T;

function dependent<Base extends { id: number }, Left extends Base, Right extends { other: string }>(key: keyof (Left & Right)) {
  const result = take(key);
  const reveal: never = result;
  result.id;
  result.other;
  return reveal;
}

function subtype<Left extends { a: number }, Right extends Left & { b: string }>(key: keyof (Left & Right)) {
  const result = take(key);
  const reveal: never = result;
  result.a;
  result.b;
  return reveal;
}

function three<A extends { a: number }, B extends { b: string }, C extends { c: boolean }>(key: keyof (A & B & C)) {
  const result = take(key);
  const reveal: never = result;
  result.a;
  result.b;
  result.c;
  return reveal;
}
void [dependent, subtype, three];
