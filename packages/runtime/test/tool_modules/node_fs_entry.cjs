const fs = require("node:fs");
const expected = require("./node_fs_utf8.expected.json");
const path = __dirname + "/node_fs_utf8.bin";
if (fs !== require("fs") || require.resolve("node:fs") !== "node:fs" || require.resolve("fs") !== "fs") {
  throw new Error("builtin resolution lost identity");
}
if (!require("./node_fs_esm.mjs").okay) throw new Error("ESM builtin imports did not share the real adapter");
if (!fs.existsSync(path) || !fs.existsSync(__dirname) || fs.existsSync(path + ".missing") || fs.existsSync(path + "\0")) {
  throw new Error("existsSync did not inspect the real filesystem");
}
for (const encoding of ["utf8", "UTF-8", { encoding: "utf8", flag: "r" }]) {
  if (fs.readFileSync(path, encoding) !== expected.text) throw new Error("UTF-8 decoding differs from Node");
}
let failed = false;
try { fs.readFileSync(path + ".missing", "utf8"); } catch { failed = true; }
if (!failed) throw new Error("missing file was treated as readable");
failed = false;
try { fs.readFileSync(path + "\0", "utf8"); } catch { failed = true; }
if (!failed) throw new Error("NUL path read a different file");
console.log("OK home-tool node:fs UTF-8 reads");
