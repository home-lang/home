const state = { trace: [] };
state.promise = new Promise(function(resolve) { state.resolve = resolve; });
module.exports = state;
