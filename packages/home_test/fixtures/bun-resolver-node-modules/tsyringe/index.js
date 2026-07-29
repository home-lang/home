exports.singleton = () => target => target;
exports.container = {
  resolve(target) {
    return new target();
  },
};
