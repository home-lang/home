const a = !"a";
const b = !0n;
const c = !1n;
const d = !(() => 1);
const e = !`x`;
if ("a") {}
const f = 0n ? 1 : 2;

if (0n) {}
while (`x`) { break; }
const g = "a" && 1;
const h = 0n || 1;
const i = `x` && 1;
const j = {} ?? 1;
const k = !("a");
function shadowed(undefined: any) { if (undefined) {} }

export {};
