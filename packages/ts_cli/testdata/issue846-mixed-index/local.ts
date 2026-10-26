type ReadonlyStrings = { readonly [key: string]: number; [index: number]: number };
declare let strings: ReadonlyStrings;
strings["new"] = 2;
strings[0] = 2;
strings["0"] = 2;

interface ReadonlyNumbers { [key: string]: number; readonly [index: number]: number }
declare let numbers: ReadonlyNumbers;
numbers["new"] = 2;
numbers[0] = 2;
numbers["0"] = 2;

class ReadonlyStringClass {
  readonly [key: string]: number;
  [index: number]: number;
}
declare let stringClass: ReadonlyStringClass;
stringClass["new"] = 2;
stringClass[0] = 2;
stringClass["0"] = 2;

class ReadonlyNumberClass {
  [key: string]: number;
  readonly [index: number]: number;
}
declare let numberClass: ReadonlyNumberClass;
numberClass["new"] = 2;
numberClass[0] = 2;
numberClass["0"] = 2;

interface GenericBase<T> { readonly [key: string]: T; [index: number]: T }
interface GenericDerived<T> extends GenericBase<T> {}
declare let generic: GenericDerived<number>;
generic["new"] = 2;
generic[0] = 2;
generic["0"] = 2;

class BaseMixed {
  [key: string]: number;
  readonly [index: number]: number;
}
class DerivedMixed extends BaseMixed {}
declare let derived: DerivedMixed;
derived["new"] = 2;
derived[0] = 2;
derived["0"] = 2;

declare const sym: unique symbol;
type ReadonlySymbols = { [key: string]: number; readonly [key: symbol]: number };
declare let symbols: ReadonlySymbols;
symbols["new"] = 2;
symbols[sym] = 2;

type ReadonlyStringSymbols = { readonly [key: string]: number; [key: symbol]: number };
declare let stringSymbols: ReadonlyStringSymbols;
stringSymbols.new = 2;
stringSymbols[sym] = 2;
