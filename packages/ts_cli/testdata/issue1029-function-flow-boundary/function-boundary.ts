declare const items: number[];
function evolving() {
  let x;
  for (const i of items) { x = i; }
}
function later() {
  let x: string | undefined;
  x = "a";
  for (const i of items) { if (!x) { x = "b"; } x.length; }
}
export {};
