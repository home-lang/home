declare const c: boolean;

function probe() {
  let numberValue;
  const first = c && (numberValue = 0);
  const numberTarget: "q" = numberValue;

  let stringValue;
  const second = c && (stringValue = "ok");
  const stringTarget: number = stringValue;
}

export {};
