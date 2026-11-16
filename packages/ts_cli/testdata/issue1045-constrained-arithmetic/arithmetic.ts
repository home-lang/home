function constrained<T extends number, B extends bigint>(t: T, b: B) {
  const subtract = t - 1;
  const multiply = b * 2n;
  const bits = t | 1;
  let x = t;
  x -= 1;
  t += 1;
  b *= 2n;
  t++;
}

function unconstrained<T>(t: T) {
  const reject = t - 1;
}
