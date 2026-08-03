declare const Home: {
  readonly engine: "zig-js" | "jsc";
  readTextFile(path: string): string;
  writeTextFile(path: string, contents: string): void;
  fileExists(path: string): boolean;
  spawnSync(argv: string[]): { exitCode: number | null; stdout: string; stderr: string };
};
declare function require(specifier: string): any;

import { expectedEngineMarker } from "./tool_smoke_helper";
import { packageValue } from "./tool_smoke_package";

const smokeData = require("./tool_smoke_data.json");
if (smokeData.name !== "home-tool" || packageValue !== 42) {
  throw new Error("Home module resolution did not load JSON and package main entries");
}
if (require("./tool_smoke_helper") !== require("./tool_smoke_helper")) {
  throw new Error("Home CommonJS module cache did not preserve export identity");
}
const cycle = require("./tool_smoke_cycle_a");
if (cycle.name !== "a" || cycle.fromB !== "b" || cycle.sawA !== "a") {
  throw new Error("Home CommonJS cycle did not expose partially initialized exports");
}

const marker = "/tmp/home-tool-smoke.txt";
Home.writeTextFile(marker, expectedEngineMarker(Home.engine));
if (!Home.fileExists(marker) || Home.readTextFile(marker) !== expectedEngineMarker(Home.engine)) {
  throw new Error("Home filesystem host functions do not round-trip");
}

const child = Home.spawnSync(["printf", "home-tool"]);
if (child.exitCode !== 0 || child.stdout !== "home-tool" || child.stderr !== "") {
  throw new Error("Home.spawnSync returned an unexpected result");
}

if (process.argv[1] !== "packages/runtime/src/jsc/tool_smoke.ts") {
  throw new Error("home-tool did not expose the script path in process.argv");
}
