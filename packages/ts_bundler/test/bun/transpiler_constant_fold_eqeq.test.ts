// Copied from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: test/bundler/transpiler_constant_fold_eqeq.test.ts
// See LICENSE.bun.md for full license text.
test("constant fold ==", () => {
  // @ts-expect-error
  expect("0" + "1" == 0).toBe(false);
});
