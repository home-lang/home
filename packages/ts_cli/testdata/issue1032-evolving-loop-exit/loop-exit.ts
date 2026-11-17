declare const items: number[];
function f() {
  let x;
  for (const i of items) { x = i; }
  const r: "q" = x;
}
export {};
