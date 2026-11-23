function write<T extends any>() {
  const key: keyof T = "bad";
  const tuple: [number, string, keyof T] = [1, "ok", "bad"];
  return [key, tuple];
}

function guaranteed<T extends { present: number; 42: string }>() {
  const keys: [keyof T, keyof T] = ["present", 42];
  return keys;
}

function assign<T extends any>() {
  let keys: [keyof T] = [] as any;
  keys = ["bad"];
  return keys;
}

function assignNamed<T extends { present: number }>() {
  let keys: [keyof T] = [] as any;
  keys = ["present"];
  keys = ["missing"];
  return keys;
}

declare function infer<T>(first: keyof T, second: keyof T): T;
const value = infer("alpha", "beta");
value.alpha;
value.beta;
value.missing;

void [write, guaranteed, assign, assignNamed];
