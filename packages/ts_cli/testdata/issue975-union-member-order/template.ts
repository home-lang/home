// A template literal type over a union is printed as the union of its
// strings, by value.
const s1: `${"b" | "a"}` = "c";
const s2: `x${"b" | "a"}` = "c";
const s3: `${"b" | "a"}${"d" | "c"}` = "z";
const s4: `${"zeta" | "alpha" | "mid"}` = "q";
type K = `${"b" | "a"}`;
const s5: K = "c";
const s6: `${1 | "a"}-${true | 2n}` = "x";
void [s1, s2, s3, s4, s5, s6];
export {};
