declare const s1: boolean | "a";
declare const s2: "a" | "b";
declare const s3: 1 | "a";
declare const s4: symbol | "a" | 1 | boolean;
const a: { z: 1 } = s1;
const b: { z: 1 } = s2;
const c: { z: 1 } = s3;
const d: { z: 1 } = s4;
const e: 1 | "b" = s3;
