const before = [typeof require, typeof exports, typeof __filename, typeof __dirname, typeof module];
var require = 1, exports = 2, __filename = 3, __dirname = 4, module = 5;
export const result = [before, [require, exports, __filename, __dirname, module]];
