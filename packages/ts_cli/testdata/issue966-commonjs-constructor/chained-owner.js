var A = function A() {
  this.a = 1;
};
var B = function B() {
  this.b = 2;
};
exports.A = A;
exports.B = B;
A.prototype = B.prototype = {
  /** @param {number} n */
  m: function (n) {
    return n + 1;
  },
};
