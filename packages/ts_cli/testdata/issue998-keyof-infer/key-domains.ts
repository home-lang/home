declare function fromKey<T>(key: keyof T): T;

function stringNumber<K extends string | number>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.anything;
  return reveal;
}

function stringSymbol<K extends string | symbol>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.anything;
  return reveal;
}

function numberSymbol<K extends number | symbol>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  return reveal;
}

function literalNumber<K extends "x" | number>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.x;
  return reveal;
}

function literalSymbol<K extends "x" | symbol>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.x;
  return reveal;
}

function propertyKey<K extends string | number | symbol>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  return reveal;
}

void [stringNumber, stringSymbol, numberSymbol, literalNumber, literalSymbol, propertyKey];
