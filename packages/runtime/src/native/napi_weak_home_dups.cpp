// Temporary weak N-API bridge stubs for Home's native Bun-object link slice.

#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define HOME_WEAK __attribute__((weak))
#else
#define HOME_WEAK
#endif

namespace JSC {
class JSGlobalObject;
class JSObject;
class ThrowScope;
}

namespace Zig {
class GlobalObject;
}

struct NapiEnv;
struct napi_property_descriptor;
using napi_env = NapiEnv *;
using napi_status = uint32_t;
using napi_finalize = void (*)(napi_env, void *, void *);

extern "C" HOME_WEAK void napi_internal_cleanup_env_cpp(napi_env env) {}
extern "C" HOME_WEAK void napi_internal_remove_finalizer(napi_env env, napi_finalize callback, void *hint, void *data) {}
extern "C" HOME_WEAK void napi_internal_check_gc(napi_env env) {}
extern "C" HOME_WEAK uint32_t napi_internal_get_version(napi_env env) {
  return 10;
}

extern "C" HOME_WEAK JSC::JSGlobalObject *NapiEnv__globalObject(napi_env env) {
  return nullptr;
}

extern "C" HOME_WEAK bool NapiEnv__getAndClearPendingException(napi_env env, void *exception) {
  return false;
}

extern "C" HOME_WEAK void NapiEnv__ref(napi_env env) {}
extern "C" HOME_WEAK void NapiEnv__deref(napi_env env) {}

extern "C" HOME_WEAK napi_status napi_set_last_error(napi_env env, napi_status status) {
  return status;
}

namespace Napi {
HOME_WEAK void defineProperty(napi_env env, JSC::JSObject *to, const napi_property_descriptor &property, bool isInstance, JSC::ThrowScope &scope) {}
HOME_WEAK void executePendingNapiModule(Zig::GlobalObject *globalObject) {}
}

// `napi_module_register` (the legacy N-API addon registration entry,
// `void napi_module_register(napi_module*)`) is referenced by
// `Bun::Process_functionDlopen` in BunProcess.cpp.o but its only definition
// lives in `src/jsc/bindings/napi.cpp.o`, which `build.zig` deliberately skips
// (`native_skip_paths`). The main executable dead-strips the unused dlopen
// path, but the home_rt test target keeps it and fails to link without a
// definition. Provide a weak no-op so the link resolves; if napi.cpp.o is ever
// un-skipped, its strong definition wins.
extern "C" HOME_WEAK void napi_module_register(void *mod) {}

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
