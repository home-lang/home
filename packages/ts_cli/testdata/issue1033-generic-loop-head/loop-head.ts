declare const items: number[];
declare function pick<T>(x: T): T;
declare function maybe(): string | undefined;

function explicit() {
  let s: string | undefined = "a";
  for (const i of items) { s.length; s = pick<string | undefined>(undefined); }
}

async function awaited() {
  let s: string | undefined = "a";
  for (const i of items) { s.length; s = await Promise.resolve(maybe()); }
}

function inferred() {
  let s: string | undefined = "a";
  for (const i of items) { s.length; s = pick(maybe()); }
}

export {};
