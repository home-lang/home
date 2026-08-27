interface Object {}
interface Function {}
interface CallableFunction extends Function {}
interface NewableFunction extends Function {}
interface IArguments { readonly length: number; [index: number]: unknown; }
interface String {}
interface Number {}
interface Boolean {}
interface RegExp {}
interface Array<T> { readonly length: number; [index: number]: T; }
interface ReadonlyArray<T> { readonly length: number; readonly [index: number]: T; }
