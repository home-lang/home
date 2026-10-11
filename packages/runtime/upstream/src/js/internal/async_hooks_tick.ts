// Shared IDs and execution scopes for explicit AsyncResource and TickObject
// transitions. Promise/timer/native IO integration remains incomplete.
const tickInitHooks = [];
const beforeHooks = [];
const afterHooks = [];
const destroyHooks = [];
let nextAsyncId = 1;
let execution = { asyncId: 1, triggerAsyncId: 0, resource: Object.create(null) };

function dispatch(hooks, ...args) {
  for (const hook of hooks.slice()) {
    try { hook(...args); }
    catch (error) {
      try { console.error(typeof error?.stack === "string" ? error.stack : error); } catch {}
      process.exit(1);
    }
  }
}
function emitInit(id, type, trigger, resource) { dispatch(tickInitHooks, id, type, trigger, resource); }
function emitBefore(id) { dispatch(beforeHooks, id); }
function emitAfter(id) { dispatch(afterHooks, id); }
function emitDestroy(id) { queueMicrotask(() => dispatch(destroyHooks, id)); }

export default {
  tickInitHooks, beforeHooks, afterHooks, destroyHooks,
  emitInit, emitBefore, emitAfter, emitDestroy,
  newAsyncId() { return ++nextAsyncId; },
  executionAsyncId() { return execution.asyncId; },
  triggerAsyncId() { return execution.triggerAsyncId; },
  executionAsyncResource() { return execution.resource; },
  enterAsyncScope(asyncId, triggerAsyncId, resource) {
    const previous = execution;
    execution = { asyncId, triggerAsyncId, resource };
    return previous;
  },
  leaveAsyncScope(previous) { execution = previous; },
};
