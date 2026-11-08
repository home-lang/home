let calls = 0;
const receiver = {
  next() {
    calls += 1;
    return this;
  },
};
const result = receiver.next().next().next().next().next().next().next().next()
  .next().next().next().next().next().next().next().next();
if (result !== receiver || calls !== 16) {
  throw new Error("runtime transpilation changed method calls");
}
let value = 0;
if (false); else value = 42;
if (value !== 42) {
  throw new Error("runtime emission rejected a valid empty if body");
}
const coefficient: bigint = 0xfffffffffffffn;
const exponent: bigint = 0x7ffn;
if (coefficient !== 4503599627370495n || exponent !== 2047n
  || 0o755n !== 493n || 0b1010n !== 10n || 0XCA_FEn !== 51966n) {
  throw new Error("runtime transpilation changed radix BigInt values");
}
function get() {
  return 41;
}
function set(value: number) {
  return value + 1;
}
interface Files { get: typeof get, set: typeof set }
const files: Files = { get, set };
if (files.get() !== 41 || files.set(files.get()) !== 42) {
  throw new Error("runtime transpilation changed contextual type query bindings");
}
const BOOT_SLOT = Symbol.for('home.runtime.boot');
const DISPATCH_OBSERVER = Symbol.for('home.runtime.dispatch');
interface BootHost {
  [BOOT_SLOT]?: Promise<number>
  [DISPATCH_OBSERVER]?: (event: string) => void
}
const ready = Promise.resolve(7);
const observed: string[] = [];
const boot: BootHost = {
  [BOOT_SLOT]: ready,
  [DISPATCH_OBSERVER]: event => {
    observed.push(event);
  },
};
boot[DISPATCH_OBSERVER]!('ready');
if (boot[BOOT_SLOT] !== ready || observed.join() !== 'ready'
  || Object.getOwnPropertySymbols(boot).length !== 2) {
  throw new Error("runtime transpilation conflated registry-symbol keys");
}
console.log("OK home-tool runtime transpilation");
