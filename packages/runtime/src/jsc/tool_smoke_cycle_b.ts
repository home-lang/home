declare function require(specifier: string): any;
declare const exports: any;

const cycleA = require("./tool_smoke_cycle_a");
exports.name = "b";
exports.sawA = cycleA.name;
