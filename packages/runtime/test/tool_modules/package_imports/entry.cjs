const value = require("#value");
if (value.value !== 42 || value !== require("#alias") || value !== require("./value.cjs")) {
  throw new Error("package imports lost module identity");
}
if (require("./nested/check.cjs") !== 17) throw new Error("nested scope was not used");
if (require("./esm.mjs").default !== 42) throw new Error("ESM private import was not resolved");
if (require("./no_imports/check.cjs") !== true) throw new Error("private import escaped package scope");
if (require("./node_modules/no_package/check.cjs") !== true) throw new Error("private import escaped node_modules");
for (const name of ["#missing", "#blocked", "#escape", "#traversal", "#encoded", "#extensionless"]) {
  let failed = false;
  try { require(name); } catch { failed = true; }
  if (!failed) throw new Error("invalid package import resolved: " + name);
}
console.log("OK home-tool exact package imports");
