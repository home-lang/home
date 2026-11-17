function fixed(flag: false, text: "", zero: 0) {
  if (flag) { const a: string = flag; }
  if (text) { const b: number = text; }
  if (zero) { const c: string = zero; }
}

function assigned() {
  let flag = false;
  if (flag) { const a: string = flag; }
  let text: "" = "";
  if (text) { const b: number = text; }
  let zero: 0 = 0;
  if (zero) { const c: string = zero; }
}

function equality(value: "a") {
  if (value === "b") { const result: number = value; }
}

function typeguard(value: number) {
  if (typeof value === "string") { const result: string = value; }
}

export {};
