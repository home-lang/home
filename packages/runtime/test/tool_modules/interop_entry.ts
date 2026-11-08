declare function require(specifier: string): any;
import common from "./interop_commonjs.cjs";
import * as namespace from "./interop_commonjs.cjs";
import standardDefault from "./interop_esm";
import { named } from "./interop_esm";
import primitive from "./interop_primitive.cjs";
import * as primitiveNamespace from "./interop_primitive.cjs";

if (common !== require("./interop_commonjs.cjs") || common.value !== 42 ||
    namespace.default !== common || namespace.value !== 42 ||
    standardDefault !== 17 || named !== 42 ||
    primitive !== 0 || primitiveNamespace.default !== 0) {
  throw new Error("default or namespace import lost CommonJS/ESM identity");
}
console.log("OK home-tool module interop");
