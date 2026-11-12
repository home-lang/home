// A loop binding whose initializer does not resolve leaves no narrow behind.
// Home used to keep one under the binding's name, which hid the next
// unresolved read of that name.
function afterLoop() {
  for (let i = missingStart; i < 3; i++) { }
  return i;
}

function nextLoop(o: object) {
  for (let k = missingKey; k; ) { }
  for (const p in k) { }
  return o;
}
export {};
