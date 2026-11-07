declare function require(specifier: string): any;

export const meta = import.meta;
if (meta !== import.meta || Object.getPrototypeOf(meta) !== null) {
  throw new Error("import.meta must have stable identity and a null prototype");
}
if (!meta.main || !meta.path.endsWith("/import_meta_entry.ts") ||
    meta.url !== "file://" + meta.path.split("/").map(encodeURIComponent).join("/") ||
    meta.dir + "/" + meta.file !== meta.path) {
  throw new Error("entry module metadata does not describe its source file");
}
if (!Object.isExtensible(meta)) {
  throw new Error("import.meta must remain extensible host data");
}
if (require(meta.path).meta !== meta) {
  throw new Error("relative and absolute imports did not share module identity");
}
if (meta.dirname !== meta.dir || meta.filename !== meta.path || meta.env !== process.env) {
  throw new Error("module metadata aliases lost their host identity");
}
if (require("./import_meta_arguments.cjs") !== 42) {
  throw new Error("module metadata broke CommonJS loading");
}
const child = require("./import_meta_child");
if (child.meta.main || child.meta === meta ||
    child.meta.file !== "import_meta_child.ts" ||
    child.readMeta({}, {}) !== child.meta ||
    require("./import_meta_child").meta !== child.meta) {
  throw new Error("import.meta lost imported module identity or lexical scope");
}
const escaped = require("./import_meta space#%.ts").meta;
if (!escaped.url.endsWith("/import_meta%20space%23%25.ts") || escaped.main ||
    meta.require("./import_meta_child").meta !== child.meta) {
  throw new Error("module metadata did not preserve URL escaping or local require");
}
function nested(module: unknown, __home_import_meta_0: unknown) {
  return import.meta;
}
const __home_import_meta_1 = "user binding";
if (nested({}, {}) !== meta || __home_import_meta_1 !== "user binding") {
  throw new Error("host metadata captured or collided with a source binding");
}
const text = "import.meta";
const object = { import: { meta: 42 } };
if (text !== "import.meta" || object.import.meta !== 42 || !/import\.meta/.test(text)) {
  throw new Error("metadata lowering changed non-syntax source text");
}
console.log("OK home-tool import.meta");
