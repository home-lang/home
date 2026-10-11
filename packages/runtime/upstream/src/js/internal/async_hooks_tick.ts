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

const fsRequestStates = new WeakMap();
class FSReqPromise {}
class FSReqCallback {}
function createFSRequest(promise) {
  const resource = new FSReqPromise();
  resource.promise = promise;
  const state = { id: ++nextAsyncId, trigger: execution.asyncId, destroyed: false, frame: $getInternalField($asyncContext, 0) };
  fsRequestStates.set(resource, state);
  emitInit(state.id, "FSREQPROMISE", state.trigger, resource);
  return resource;
}
function createFSCallback(callback) {
  const resource = new FSReqCallback();
  resource.oncomplete = callback;
  const state = { id: ++nextAsyncId, trigger: execution.asyncId, destroyed: false, frame: $getInternalField($asyncContext, 0) };
  fsRequestStates.set(resource, state);
  emitInit(state.id, "FSREQCALLBACK", state.trigger, resource);
  return resource;
}
function deliverFSCallback(resource, result, failed) {
  resource.oncomplete.$call(undefined, failed ? result : null, failed ? undefined : result);
}
function queueFSCallback(callback, error) { process.nextTick(callback, error); }
function enterFSRequest(resource) {
  const state = fsRequestStates.get(resource);
  const previous = { execution, frame: $getInternalField($asyncContext, 0) };
  execution = { asyncId: state.id, triggerAsyncId: state.trigger, resource };
  $putInternalField($asyncContext, 0, state.frame);
  emitBefore(state.id);
  return previous;
}
function leaveFSRequest(resource, previous) {
  emitAfter(fsRequestStates.get(resource).id);
  execution = previous.execution;
  $putInternalField($asyncContext, 0, previous.frame);
}
function destroyFSRequest(resource) {
  const state = fsRequestStates.get(resource);
  if (!state.destroyed) { state.destroyed = true; emitDestroy(state.id); }
}

export default {
  tickInitHooks, beforeHooks, afterHooks, destroyHooks,
  createTimer, destroyTimer, refreshTimer, enterTimer, leaveTimer,
  createFSRequest, createFSCallback, deliverFSCallback, queueFSCallback, enterFSRequest, leaveFSRequest, destroyFSRequest,
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
