// Worker context cleanup bridge. The former weak N-API placeholders were
// removed when Home began compiling its complete napi.cpp binding.

#include <stdint.h>

// --- Terminated-worker context-map cleanup ---------------------------------
// A Worker's ScriptExecutionContext is normally removed from the global
// `allScriptExecutionContextsMap` by GlobalObject::~GlobalObject(). In Home's
// worker teardown the global outlives WebWorker__teardownJSCVM (its refcount
// does not reach zero synchronously there), so the context lingers in the map
// with a dangling identifier after the worker's event loop/VM is freed. A later
// cross-thread post — e.g. BroadcastChannel dispatch from another thread —
// resolves that identifier via ScriptExecutionContext::postTaskTo() and posts
// to the worker's already-freed event loop → use-after-free
// (event_loop.zig enqueueTaskConcurrent segfaults on the freed VM pointer).
//
// Remove the context from the map explicitly during worker shutdown, before the
// loop/VM is freed, so postTaskTo() can no longer find it (it returns false and
// the task is dropped — exactly what real Bun relies on). Forward-declared to
// avoid pulling WebCore headers into this lightweight bridge TU; the two
// symbols are defined in the linked bindings objs
// (getScriptExecutionContext(unsigned int) / removeFromContextsMap()).
namespace WebCore {
class ScriptExecutionContext {
public:
  static ScriptExecutionContext *getScriptExecutionContext(unsigned int identifier);
  void removeFromContextsMap();
};
} // namespace WebCore

extern "C" void Bun__ScriptExecutionContext__removeFromContextsMapByIdentifier(uint32_t identifier) {
  if (auto *context = WebCore::ScriptExecutionContext::getScriptExecutionContext(identifier))
    context->removeFromContextsMap();
}
