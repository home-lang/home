function declaredClass() {
  class A { value = x; }
  let x;
  return A;
}

function expressionClass() {
  const A = class { value = x; };
  let x;
  return A;
}

export {};
