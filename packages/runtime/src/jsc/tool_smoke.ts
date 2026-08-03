declare const Home: {
  readonly engine: "zig-js" | "jsc";
  readTextFile(path: string): string;
  writeTextFile(path: string, contents: string): void;
  readFileHex(path: string): string;
  writeFileHex(path: string, contents: string): void;
  fileExists(path: string): boolean;
  cpuCount(): number;
  spawnSync(
    argv: string[],
    options?: {
      cwd?: string;
      timeoutMs?: number;
      env?: Record<string, string>;
      inheritEnv?: boolean;
    },
  ): {
    exitCode: number | null;
    stdout: string;
    stderr: string;
    timedOut: boolean;
  };
};
declare function require(specifier: string): any;

import { expectedEngineMarker } from "./tool_smoke_helper";
import { packageValue } from "./tool_smoke_package";

const smokeData = require("./tool_smoke_data.json");
if (smokeData.name !== "home-tool" || packageValue !== 42) {
  throw new Error(
    "Home module resolution did not load JSON and package main entries",
  );
}
if (require("./tool_smoke_helper") !== require("./tool_smoke_helper")) {
  throw new Error(
    "Home CommonJS module cache did not preserve export identity",
  );
}
const cycle = require("./tool_smoke_cycle_a");
if (cycle.name !== "a" || cycle.fromB !== "b" || cycle.sawA !== "a") {
  throw new Error(
    "Home CommonJS cycle did not expose partially initialized exports",
  );
}

const marker = "/tmp/home-tool-smoke.txt";
Home.writeTextFile(marker, expectedEngineMarker(Home.engine));
if (
  !Home.fileExists(marker) ||
  Home.readTextFile(marker) !== expectedEngineMarker(Home.engine)
) {
  throw new Error("Home filesystem host functions do not round-trip");
}
const binaryMarker = "/tmp/home-tool-smoke.bin";
Home.writeFileHex(binaryMarker, "00017fff80fe");
if (Home.readFileHex(binaryMarker) !== "00017fff80fe") {
  throw new Error("Home binary filesystem host functions do not round-trip");
}
if (!Number.isInteger(Home.cpuCount()) || Home.cpuCount() < 1) {
  throw new Error("Home.cpuCount did not report a positive integer");
}

const child = Home.spawnSync(["printf", "home-tool"]);
if (
  child.exitCode !== 0 ||
  child.stdout !== "home-tool" ||
  child.stderr !== ""
) {
  throw new Error("Home.spawnSync returned an unexpected result");
}
const inheritedHome = Home.spawnSync(["printenv", "HOME"]);
if (inheritedHome.exitCode !== 0 || !inheritedHome.stdout.trim()) {
  throw new Error("Home.spawnSync did not inherit the parent environment");
}
const configured = Home.spawnSync(
  ["sh", "-c", 'printf \'%s:%s\' "$HOME_TOOL_SMOKE" "$(pwd)"'],
  {
    cwd: "/tmp",
    env: { HOME_TOOL_SMOKE: "configured" },
  },
);
if (
  configured.exitCode !== 0 ||
  !["configured:/tmp", "configured:/private/tmp"].includes(configured.stdout) ||
  configured.timedOut
) {
  throw new Error(
    `Home.spawnSync did not apply cwd and environment options: ${JSON.stringify(configured)}`,
  );
}
const timed = Home.spawnSync(["sleep", "1"], { timeoutMs: 10 });
if (!timed.timedOut || timed.exitCode !== null) {
  throw new Error("Home.spawnSync did not enforce its timeout");
}

if (process.argv[1] !== "packages/runtime/src/jsc/tool_smoke.ts") {
  throw new Error("home-tool did not expose the script path in process.argv");
}
