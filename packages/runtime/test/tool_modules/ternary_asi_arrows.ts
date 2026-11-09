// A later assignment/arrow must not turn the preceding ternary arm into
// a typed arrow parameter list, even when the statements use ASI.
function declarationProbe(heartbeat: any) {
  const interval = typeof heartbeat === "object" ? (heartbeat.interval ?? 10) : 10
  const next = () => 42
  return [interval, next()]
}

function assignmentProbe(heartbeat: any) {
  const interval = typeof heartbeat === "object" ? (heartbeat.interval ?? 10) : 10
  let next
  next = () => 42
  return [interval, next()]
}

function functionProbe(heartbeat: any) {
  const interval = typeof heartbeat === "object" ? (heartbeat.interval ?? 10) : 10
  function next() { return 42 }
  return [interval, next()]
}

let witnesses = 0;
for (const [heartbeat, expected] of [
  [false, 10],
  [true, 10],
  [{ interval: 0 }, 0],
  [{ interval: 5 }, 5],
  [{ interval: null }, 10],
  [{ interval: undefined }, 10],
]) {
  for (const probe of [declarationProbe, assignmentProbe, functionProbe]) {
    const result = probe(heartbeat);
    if (result[0] !== expected || result[1] !== 42) {
      throw new Error("Ternary/ASI arrow execution changed");
    }
    witnesses++;
  }
}
const withDefault = (value = 7): number => value;
const source = { function: 7 };
const read = (): typeof source.function => source.function;
if (witnesses !== 18 || withDefault() !== 7 || withDefault(3) !== 3 || read() !== 7) {
  throw new Error("Incomplete ASI witnesses or broken typed arrow return");
}
