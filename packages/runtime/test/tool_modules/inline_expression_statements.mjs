function check(value, message) { if (!value) throw new Error(message); }
let value = 0;
if (true) ({ value } = { value: 1 });
else ({ value } = { value: 99 });
check(value === 1, 'if destructuring');
if (false) ({ value } = { value: 99 });
else ({ value } = { value: 2 });
check(value === 2, 'else destructuring');
while (value < 3) ({ value } = { value: 3 });
check(value === 3, 'while destructuring');
for (; value < 4;) ({ value } = { value: 4 });
check(value === 4, 'for destructuring');
do ({ value } = { value: 5 }); while (value < 5);
check(value === 5, 'do destructuring');
label: ({ value } = { value: 6 });
check(value === 6, 'labeled destructuring');
if (true) ({ ['key']: value++ });
check(value === 7, 'object expression effect');
let calls = 0;
if (true) (function() { calls++; })();
check(calls === 1, 'inline function expression');
function originalLookup() {
  let resolvedFileName;
  let originalPath;
  if (!false) ({ resolvedFileName, originalPath } = { resolvedFileName: 'file', originalPath: 'link' });
  return resolvedFileName + ':' + originalPath;
}
check(originalLookup() === 'file:link', 'actual TypeScript lookup shape');
console.log('OK inline expression statement grouping and actual destructuring effects');
