interface Alpha<T> { make(): Beta<T> }
interface Beta<T> extends Alpha<T>, MixedBase<T> {}
interface MixedBase<T> { readonly [key: string]: unknown; [index: number]: T }
declare const alpha: Alpha<number>;
const beta = alpha.make();
beta["new"] = 2;
beta[0] = 2;
beta["0"] = 2;

interface NumberSource<T> { make(): NumberResult<T> }
interface NumberResult<T> extends NumberSource<T>, NumberBase<T> {}
interface NumberBase<T> { [key: string]: unknown; readonly [index: number]: T }
declare const numberSource: NumberSource<number>;
const numberResult = numberSource.make();
numberResult["new"] = 2;
numberResult[0] = 2;
numberResult["0"] = 2;

interface SymbolSource<T> { make(): SymbolResult<T> }
interface SymbolResult<T> extends SymbolSource<T>, SymbolBase<T> {}
interface SymbolBase<T> { [key: string]: unknown; readonly [key: symbol]: T }
declare const symbolSource: SymbolSource<number>;
declare const symbolKey: unique symbol;
const symbolResult = symbolSource.make();
symbolResult["new"] = 2;
symbolResult[symbolKey] = 2;
