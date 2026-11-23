declare function fromKey<T>(key: keyof T): T;

function genericIntersection<U extends { a: number }, V extends { b: string }, K extends keyof (U & V)>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.a;
  value.b;
  return reveal;
}

function genericUnion<U extends { common: number; a: string }, V extends { common: number; b: boolean }, K extends keyof (U | V)>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.common;
  return reveal;
}

type A = { a: number };
type B = { b: string };
function concreteIntersection<K extends keyof (A & B)>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.a;
  value.b;
  value.missing;
  return reveal;
}

type C = { common: number; a: string };
type D = { common: number; b: boolean };
function concreteUnion<K extends keyof (C | D)>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  return reveal;
}

function mixedIntersection<U extends { present: number }, K extends keyof (U & { fixed: string })>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.fixed;
  return reveal;
}

function mixedUnion<U extends { present: number }, K extends keyof (U | { extra: string; present: number })>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.present;
  value.extra;
  value.missing;
  return reveal;
}

void [genericIntersection, genericUnion, concreteIntersection, concreteUnion, mixedIntersection, mixedUnion];
