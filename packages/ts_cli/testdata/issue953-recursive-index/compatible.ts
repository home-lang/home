interface Derived<T> extends Base<T> {}
interface Base<T> { readonly [key: string]: T | (() => T); [index: number]: T }
declare let value: Derived<number>;
value[0] = 2;
value["0"] = 2;
