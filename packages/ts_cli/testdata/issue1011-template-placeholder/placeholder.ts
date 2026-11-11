enum E { A = 1, B = "b" }
type F<T extends string | number | bigint | boolean | null | undefined> = `${T}`;

// A literal placeholder is folded into the text, whatever its kind.
const n1: `${1}` = "2";
const n2: `a${2}b` = "a3b";
const n3: `${-1}` = "1";
const n4: `${0.5}` = "1";
const n5: `${1e21}` = "1";
const n6: `${1e-7}` = "1";
const n7: `${0x10}` = "1";
const n8: `${-0}` = "x";
const n9: `${0.1}` = "x";
const b1: `${1n}` = "2";
const b2: `${0x10n}` = "1";
const t1: `${true}` = "2";
const z1: `${null}` = "x";
const z2: `${undefined}` = "x";
const e1: `${E.A}` = "x";
const e2: `${E.B}` = "x";

// A union of literals is spread into a union of strings.
const u1: `${1 | 2}` = "3";
type U = `${1 | 2}`;
const u2: U = "3";

// So is an instantiation, and the alias name is not kept.
const g1: F<1> = "2";
const g2: F<1n> = "2";
const g3: F<1 | 2> = "3";
const g4: F<true> = "x";

// Each of these is the folded string, so it is accepted.
const ok1: `${1}` = "1";
const ok2: `${1 | 2}` = "2";
const ok3: `a${2}b` = "a2b";
const ok4: `${-1}` = "-1";
const ok5: `${1n}` = "1";
const ok6: `${0x10}` = "16";
const ok7: `${0x10n}` = "16";
const ok8: `${1e21}` = "1e+21";
const ok9: F<2> = "2";
const ok10: `${-0}` = "0";

// A placeholder that is not a literal still accepts its kind.
const p1: `${number}` = "12";
const p2: `${number}` = "x";
const p3: `a${1}${number}` = "a12";
const p4: `a${1}${number}` = "b12";
void [n1, n2, n3, n4, n5, n6, n7, n8, n9, b1, b2, t1, z1, z2, e1, e2, u1, u2, g1, g2, g3, g4, ok1, ok2, ok3, ok4, ok5, ok6, ok7, ok8, ok9, ok10, p1, p2, p3, p4];
export {};
