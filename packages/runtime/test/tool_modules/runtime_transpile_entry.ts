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
console.log("OK home-tool runtime transpilation");
