interface RequiredValue { value: number }
interface OptionalValue { value?: number }
interface UniformValues { a: number; b: number }

declare function pick<T extends OptionalValue>(o: T): T["value"];

function generic<T extends RequiredValue>(v: string): T["value"] {
  return v;
}

function optional<T extends OptionalValue>(): T["value"] {
  return "wrong";
}

function uniform<K extends keyof UniformValues>(): UniformValues[K] {
  return "wrong";
}

const result = pick({});
const n: number | undefined = result;
