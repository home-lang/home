declare const Home: {
  readonly engine: "zig-js" | "jsc";
  readTextFile(path: string): string;
  writeTextFile(path: string, contents: string): void;
  fileExists(path: string): boolean;
  spawnSync(argv: string[]): { exitCode: number | null; stdout: string; stderr: string };
};

const marker = "/tmp/home-tool-smoke.txt";
Home.writeTextFile(marker, `engine=${Home.engine}`);
if (!Home.fileExists(marker) || Home.readTextFile(marker) !== `engine=${Home.engine}`) {
  throw new Error("Home filesystem host functions do not round-trip");
}

const child = Home.spawnSync(["/usr/bin/printf", "home-tool"]);
if (child.exitCode !== 0 || child.stdout !== "home-tool" || child.stderr !== "") {
  throw new Error("Home.spawnSync returned an unexpected result");
}

if (process.argv[1] !== "packages/runtime/src/jsc/tool_smoke.ts") {
  throw new Error("home-tool did not expose the script path in process.argv");
}
