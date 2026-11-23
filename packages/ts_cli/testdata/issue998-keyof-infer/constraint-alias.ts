declare function fromKey<T>(key: keyof T): T;

type Keys<U> = keyof U;
function genericAlias<U extends { present: number }, K extends Keys<U>>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  const present: number = value.present;
  value.missing;
  return [reveal, present];
}

type Concrete = { left: number; right: string };
type ConcreteKeys = keyof Concrete;
function concreteAlias<K extends ConcreteKeys>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.left;
  value.right;
  value.missing;
  return reveal;
}

type Single = { present: number };
function singleton<K extends keyof Single>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  return reveal;
}

type LiteralKeys = "left" | "right";
function literalUnion<K extends LiteralKeys>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  return reveal;
}

void [genericAlias, concreteAlias, singleton, literalUnion];
