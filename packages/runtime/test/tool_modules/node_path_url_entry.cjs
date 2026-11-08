const path = require("node:path");
const url = require("node:url");
const vectors = require("./node_path_url.expected.json");
if (path !== require("path") || path !== path.posix || path !== require("node:path/posix") || url !== require("url")) throw new Error("builtin identity differs");
if (path.sep !== "/" || path.delimiter !== ":" || path.resolve() !== process.cwd() || path.resolve("child", "..") !== process.cwd()) throw new Error("POSIX cwd resolution differs");
for (const vector of vectors.cases) {
  let value, error;
  try { value = (vector.module === "path" ? path : url)[vector.method](...vector.args); }
  catch (caught) { error = { name: caught.name, code: caught.code }; }
  if (JSON.stringify(error) !== JSON.stringify(vector.error) || value !== vector.value) {
    throw new Error("Node oracle mismatch: " + JSON.stringify(vector) + " actual " + JSON.stringify({ value, error }));
  }
}
console.log("OK home-tool POSIX path and file URL operations");
