interface Alpha<T> { make(): Beta<T> }
interface Beta<T> extends Alpha<T>, MixedBase<T> {}
interface MixedBase<T> { readonly [key: string]: T | (() => Beta<T>); [index: number]: T }
declare const alpha: Alpha<number>;
const beta = alpha.make();
beta["new"] = 2;
beta[0] = 2;
beta["0"] = 2;
