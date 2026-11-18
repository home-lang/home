interface Shape { a: number; b: string }
declare const arr: number[];
declare const ro: readonly number[];
declare const obj: Shape;
declare const anon: { a: number; b: string };
declare const union: Shape | { a: number; c: string };
type KA = keyof typeof arr;
type KR = keyof typeof ro;
type KO = keyof typeof obj;
type KN = keyof typeof anon;
type KU = keyof typeof union;
const a: KA = "bogus";
const b: KR = "bogus";
const c: KO = "bogus";
const d: KN = "bogus";
const e: KU = "bogus";
const f: keyof typeof arr = "bogus";
type Mixed = keyof Shape | "extra";
const mixed: Mixed = "bogus";
