declare function fromKey<T>(key: keyof T): T;

function generic<U extends { present: number }, K extends keyof U>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  const present: number = value.present;
  value.missing;
  return [reveal, present];
}

type Concrete = { other: string; present: number };
function concrete<K extends keyof Concrete>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  value.present;
  value.other;
  value.missing;
  return reveal;
}

function primitive<K extends string>(key: K) {
  const value = fromKey(key);
  const reveal: never = value;
  return reveal;
}

void [generic, concrete, primitive];
