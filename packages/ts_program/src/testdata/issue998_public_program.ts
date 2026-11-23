function write<T extends any>() {
  const key: keyof T = "bad";
  const tuple: [number, string, keyof T] = [1, "ok", "bad"];
  return [key, tuple];
}

function guaranteed<T extends { present: number; 42: string }>() {
  const keys: [keyof T, keyof T] = ["present", 42];
  return keys;
}

declare function infer<T>(first: keyof T, second: keyof T): T;
const value = infer("alpha", "beta");
value.alpha;
value.beta;
value.missing;

void [write, guaranteed];
