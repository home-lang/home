let operations = 0;
function check(value, message) { if (!value) throw new Error(message); operations++; }
let effects = 0;
let seen = [];
for (const value of (effects++, [1, 2, 3])) seen.push(value);
check(effects === 1 && seen.join() === '1,2,3', 'for-of sequence evaluates once');
let selected;
seen = [];
for (const value of (selected = [4, 5])) seen.push(value);
check(selected.join() === '4,5' && seen.join() === '4,5', 'for-of assignment source');
seen = [];
for (const value of (true ? [8] : [9])) seen.push(value);
check(seen.join() === '8', 'for-of conditional source');
seen = [];
for (const value of [10, 20].map(value => value + 1)) seen.push(value);
check(seen.join() === '11,21', 'for-of call source');
let keys = [];
for (const key in (effects++, { first: 1, second: 2 })) keys.push(key);
check(effects === 2 && keys.join() === 'first,second', 'for-in retains sequence semantics');
seen = [];
for await (const value of (effects++, [Promise.resolve(4), Promise.resolve(5)])) seen.push(value);
check(effects === 3 && seen.join() === '4,5', 'for-await sequence evaluates once');
function* values() { for (const value of (effects++, [6, 7])) yield value; }
check(Array.from(values()).join() === '6,7' && effects === 4, 'generator for-of sequence resumes correctly');
let pairs = [];
for (const left of (effects++, [1, 2])) {
  for (const right of (effects++, [1, 2])) pairs.push(left * 10 + right);
}
check(pairs.join() === '11,12,21,22' && effects === 7, 'nested for-of sequences keep evaluation order');
if (operations !== 8) throw new Error('for-of sequence operation denominator ' + operations);
