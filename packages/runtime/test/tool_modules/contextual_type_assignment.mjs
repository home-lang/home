function check(value, message) { if (!value) throw new Error(message); }
let type = '';
type = 'actual';
check(type === 'actual', 'top-level assignment');
{ let type = 0; type = 2; check(type === 2, 'block assignment'); }
export function update() {
  let type = 0;
  type = 3;
  return type;
}
export const arrow = () => {
  let type = 0;
  type = 4;
  return type;
};
check(update() === 3 && arrow() === 4, 'export modifiers must not turn body assignments into aliases');
let ty\u0070eAlias = 0;
ty\u0070eAlias = 5;
check(typeAlias === 5, 'escaped identifier control');
type = { value: 6, call(value) { return value + this.value; } };
type.value += 1;
check(type.call(1) === 8, 'member and call control');
type = 1;
type += 2;
type++;
check(type === 4, 'compound and update control');
console.log('OK actual contextual type assignments across blocks and exported function bodies');
