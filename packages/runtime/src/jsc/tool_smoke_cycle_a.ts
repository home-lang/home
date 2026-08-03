declare function require(specifier: string): any;
declare const exports: any;

exports.name = "a";
const cycleB = require("./tool_smoke_cycle_b");
exports.fromB = cycleB.name;
exports.sawA = cycleB.sawA;
