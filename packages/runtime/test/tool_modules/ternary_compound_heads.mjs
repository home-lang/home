let operations = 0;
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n += 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 3) throw new Error('compound ternary += actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n -= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 1) throw new Error('compound ternary -= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n *= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 2) throw new Error('compound ternary *= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n /= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 2) throw new Error('compound ternary /= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n %= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 0) throw new Error('compound ternary %= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n **= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 2) throw new Error('compound ternary **= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n <<= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 4) throw new Error('compound ternary <<= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n >>= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 1) throw new Error('compound ternary >>= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n >>>= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 1) throw new Error('compound ternary >>>= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n &= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 0) throw new Error('compound ternary &= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n |= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 3) throw new Error('compound ternary |= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n ^= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 3) throw new Error('compound ternary ^= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n &&= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 1) throw new Error('compound ternary &&= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n ||= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 2) throw new Error('compound ternary ||= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = function() { let n = 2; return true ? (n ??= 1) : 0 < 10; }; !calls; calls++) { value = calculate(); }
  if (calls !== 1 || value !== 2) throw new Error('compound ternary ??= actual result');
  operations++;
}
{
  let calls = 0; let value;
  for (const calculate = async function() { let n = 2; return true ? (n += 1) : 0 < 10; }; !calls; calls++) { value = await calculate(); }
  if (calls !== 1 || value !== 3) throw new Error('async compound ternary actual result');
  operations++;
}
{
  let calls = 0; let result;
  for (const calculate = function*() { let n = 2; return true ? (n += 1) : 0 < 10; }; !calls; calls++) { result = calculate().next(); }
  if (calls !== 1 || result.value !== 3 || result.done !== true) throw new Error('generator compound ternary actual result');
  operations++;
}
if (operations !== 17) throw new Error('compound ternary operation denominator ' + operations);
