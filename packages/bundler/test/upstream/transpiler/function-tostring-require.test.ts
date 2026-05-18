// Copied from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: test/bundler/transpiler/function-tostring-require.test.ts
// See LICENSE.bun.md for full license text.
import { expect, test } from "bun:test";

test("toString doesnt observe import.meta.require", () => {
  function hello() {
    return typeof require("fs") === "string" ? "from eval" : "main function";
  }
  const newFunctionBody = `return ${hello.toString()}`;
  const loadFakeModule = new Function("require", newFunctionBody)(id => `fake require ${id}`);
  expect(hello()).toBe("main function");
  expect(loadFakeModule()).toBe("from eval");
});

export {};
