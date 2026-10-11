// Shared IDs and execution scopes for explicit AsyncResource and TickObject
// transitions. Promise/native IO integration remains incomplete.
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

const timerStates = new WeakMap();
const timerRegistry = new FinalizationRegistry(state => {
  if (!state.destroyed) { state.destroyed = true; emitDestroy(state.id); }
});
function createTimer(timer, immediate) {
  const state = { id: ++nextAsyncId, trigger: execution.asyncId, destroyed: false, immediate };
  timerStates.set(timer, state);
  timerRegistry.register(timer, state, timer);
  emitInit(state.id, immediate ? "Immediate" : "Timeout", state.trigger, timer);
}
function destroyTimer(timer) {
  const state = timerStates.get(timer);
  if (state && !state.destroyed) {
    state.destroyed = true;
    timerRegistry.unregister(timer);
    emitDestroy(state.id);
  }
}
function refreshTimer(timer) {
  const state = timerStates.get(timer);
  if (state?.destroyed) createTimer(timer, state.immediate);
}
function enterTimer(timer) {
  const state = timerStates.get(timer);
  if (!state) return null;
  const previous = execution;
  execution = { asyncId: state.id, triggerAsyncId: state.trigger, resource: timer };
  emitBefore(state.id);
  return previous;
}
function leaveTimer(timer, previous) {
  if (previous === null) return;
  const state = timerStates.get(timer);
  emitAfter(state.id);
  execution = previous;
}

export default {
  tickInitHooks, beforeHooks, afterHooks, destroyHooks,
  createTimer, destroyTimer, refreshTimer, enterTimer, leaveTimer,
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
