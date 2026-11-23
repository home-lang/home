function unconstrained<T>() {
  const key: keyof T = "missing";
  return key;
}

function explicitAny<T extends any>() {
  const key: keyof T = "missing";
  return key;
}

function unknown<T extends unknown>() {
  const key: keyof T = "missing";
  return key;
}

function named<T extends { present: number }>() {
  const valid: keyof T = "present";
  const invalid: keyof T = "missing";
  return [valid, invalid];
}

function impossible<T extends never>() {
  const key: keyof T = "missing";
  return key;
}

void [unconstrained, explicitAny, unknown, named, impossible];
