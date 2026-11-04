interface Base<T> { value: T }
interface Compatible<T, U extends T, V extends T> extends Base<T> { value: U | V }

function returnCompatible<T, U extends T, V extends T>(value: U | V): T { return value; }
function returnIncompatible<T, U extends T>(value: U | number): T { return value; }

declare const item: Compatible<string, 'a', 'b'>;
const result: string = item.value;
void [returnCompatible, returnIncompatible, result];
