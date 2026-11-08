let sum = 0;
for await (const number of [Promise.resolve(1), 2]) sum += number;
if (sum !== 3) throw new Error('for await');
console.log('OK home-tool top-level for await');
