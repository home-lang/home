declare function fromKey<T>(key: keyof T): T;

function intersection<U extends { a: number }, V extends { b: string }>(key: keyof (U & V)) {
  const value = fromKey(key);
  const reveal: never = value;
  const a: number = value.a;
  value.b;
  value.missing;
  return [reveal, a];
}

function union<U extends { common: number; a: string }, V extends { common: number; b: boolean }>(key: keyof (U | V)) {
  const value = fromKey(key);
  const reveal: never = value;
  const common: number = value.common;
  value.missing;
  return [reveal, common];
}

void [intersection, union];
