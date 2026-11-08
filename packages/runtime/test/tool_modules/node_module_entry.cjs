const mod = require("node:module");
if (mod !== require("module")) throw new Error("module builtin identity differs");
const a = mod.createRequire(__dirname + "/node_module_scopes/a/not-created.cjs");
const bPath = __dirname + "/node_module_scopes/b # %/not-created.cjs";
const bURL = "file://" + bPath.split("/").map(encodeURIComponent).join("/");
const b = mod.createRequire(bURL);
if (a("./value.cjs").value !== 17 || b("./value.cjs").value !== 42 || a("./value.cjs") === b("./value.cjs")) {
  throw new Error("createRequire ignored its referrer");
}
if (a("#value") !== a("./value.cjs") || b("#value") !== b("./value.cjs")) {
  throw new Error("createRequire lost package scope or cache identity");
}
const directory = mod.createRequire(__dirname + "/node_module_scopes/a/");
if (directory("./value.cjs") !== a("./value.cjs")) throw new Error("trailing slash lost referrer directory");
const dotURL = bURL.replace("/not-created.cjs", "/unused/../not-created.cjs") + "?ignored#ignored";
if (mod.createRequire(dotURL)("./value.cjs") !== b("./value.cjs")) throw new Error("file URL normalization changed referrer");
if (mod.createRequire(bURL.replace("file://", "file://localhost"))("./value.cjs") !== b("./value.cjs")) throw new Error("localhost URL changed referrer");
for (const url of [bURL.replace("file:///", "file:/"), bURL.replace("file:///", "file:"), bURL.replace("file:", "FILE:"), bURL.replace("/not-created.cjs", "/unused/%2e%2e/not-created.cjs")]) {
  if (mod.createRequire(url)("./value.cjs") !== b("./value.cjs")) throw new Error("file URL form changed referrer");
}
const invalid = a.resolve("./invalid.cjs");
if (!invalid.endsWith("/invalid.cjs") || invalid in a.cache) throw new Error("resolve parsed or loaded a target");
if (a.resolve("fs") !== "fs" || a.resolve("node:fs") !== "node:fs" || a("node:fs") !== require("fs")) {
  throw new Error("anchored require lost builtin identity");
}
for (const bad of ["relative.js", "", 23, "https://example.com/file.js", "file:///tmp/base%2fpart.js"]) {
  let failed = false;
  try { mod.createRequire(bad); } catch (error) { failed = error instanceof TypeError; }
  if (!failed) throw new Error("invalid createRequire referrer accepted");
}
let failed = false;
try { a(23); } catch (error) { failed = error instanceof TypeError; }
if (!failed) throw new Error("non-string module id accepted");
console.log("OK home-tool anchored createRequire");
