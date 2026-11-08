type Entry = { value: number };
type Wrapped<T extends object>
  = T;
export type PublicEntry = Entry;
let type: Wrapped<PublicEntry> = { value: 1 };
type = { value: 2 };
export function update(): number {
  type = { value: 3 };
  return type.value;
}
if (type.value !== 2 || update() !== 3) throw new Error('type aliases must erase while value assignments execute');
// eslint-disable-next-line no-console -- Required native host completion witness.
console.log('OK actual type aliases erase without consuming contextual assignments');
