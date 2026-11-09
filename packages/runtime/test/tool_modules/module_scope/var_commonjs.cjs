const before = [typeof require, typeof exports, typeof __filename, typeof __dirname];
var require = 1, exports = 2, __filename = 3, __dirname = 4;
module.exports = { result: [before, [require, exports, __filename, __dirname]] };
