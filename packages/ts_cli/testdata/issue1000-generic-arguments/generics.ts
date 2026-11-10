interface Box<T> { value: T }
class Holder<T> {
  constructor(public item: T) {}
}
type Container<T> = T | { tag: T };
interface Crate<T> { value: T }

declare const boxed: Box<string>;
declare const held: Holder<string>;
declare const mapped: Map<string, string>;
declare const setted: Set<string>;
declare const promised: Promise<string>;
declare const contained: Container<number>;

// The failing type-argument pair is the whole explanation. Walking the
// expanded bodies instead reached a property for `Box`, an index signature and
// then an entry tuple for `Map`, and the internal field name
// `__home_promise_value` for `Promise`.
const box: Box<number> = boxed;
const holder: Holder<number> = held;
const map: Map<string, number> = mapped;
const set: Set<number> = setted;
const promise: Promise<number> = promised;

// A union instantiation is explained by the member that failed, not by its
// arguments, so the shortcut must decline for it.
const container: Container<string> = contained;

// Two different generics are not the same generic, however similar they look.
const crate: Crate<number> = boxed;

// A matching argument is still accepted, and so is a widening one.
const okBox: Box<string> = boxed;
const okWide: Box<string | number> = boxed;

void box;
void holder;
void map;
void set;
void promise;
void container;
void crate;
void okBox;
void okWide;
