const object = Promise.resolve({ value: 7, method() { return this.value; } });
if ((await object).value !== 7 || (await object)['value'] !== 7 || (await object).method() !== 7) throw new Error('await member result');
if ((await Promise.resolve(function() { return 9; }))() !== 9) throw new Error('await call result');
if ((await Promise.resolve(2)) ** 3 !== 8) throw new Error('await exponentiation result');
console.log('OK home-tool await result precedence');
