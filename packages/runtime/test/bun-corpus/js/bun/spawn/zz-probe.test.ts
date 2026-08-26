import { spawn } from "bun";
import { describe, test } from "bun:test";
import { bunEnv, bunExe } from "harness";

describe("probe", () => {
  test("trace fixtures", async () => {
    const names = Object.getOwnPropertyNames(globalThis).filter(n => n.startsWith("__home_spawn_") && n.endsWith("_fixture"));
    console.log("fixture count:", names.length);
    const original = {};
    for (const name of names) {
      original[name] = globalThis[name];
      globalThis[name] = function (...args) {
        const result = original[name].apply(this, args);
        if (result) console.log("MATCHED:", name);
        return result;
      };
    }
    let pullCount = 0;
    const stream = new ReadableStream({
      pull(controller) {
        pullCount++;
        if (pullCount === 1) { controller.enqueue("chunk 1\n"); }
        else if (pullCount === 2) { controller.enqueue("chunk 2\n"); throw new Error("Pull error"); }
      },
    });
    const proc = spawn({ cmd: [bunExe(), "-e", "process.stdin.pipe(process.stdout)"], stdin: stream, stdout: "pipe", env: bunEnv });
    const text = await proc.stdout.text();
    console.log("GOT:", JSON.stringify(text));
  });
});
