function outer() {
  let g = () => g;
  let o = { m() { return o; } };
  const k = function () { return k; };
  let recursive = () => recursive();
}
export {};
