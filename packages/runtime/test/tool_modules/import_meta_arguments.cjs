if (arguments.length !== 5) {
  throw new Error("module metadata changed the CommonJS wrapper arguments");
}
module.exports = 42;
