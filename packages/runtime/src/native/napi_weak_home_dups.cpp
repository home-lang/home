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
