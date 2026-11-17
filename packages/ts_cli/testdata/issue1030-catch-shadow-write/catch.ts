function shadow() {
  let u: "a" | "b" = "a";
  try { u = "b"; } catch (u) { u = 1; }
}
function destructured() {
  let u: "a" | "b" = "a";
  try { u = "b"; } catch ({u}: any) { u = 1; }
}
export {};
