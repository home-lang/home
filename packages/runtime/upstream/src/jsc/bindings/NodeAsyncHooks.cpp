#include "config.h"

#include "JavaScriptCore/JSObject.h"
#include "JavaScriptCore/ObjectConstructor.h"
#include "JavaScriptCore/ArrayConstructor.h"

#include "ZigGlobalObject.h"
#include "root.h"
#include "InternalModuleRegistry.h"
#include <JavaScriptCore/ArgList.h>

namespace Bun {

using namespace JSC;

// `cleanupLayer` is called by js if we set async context in a way we may not
// clear it, specifically within AsyncLocalStorage.prototype.enterWith.  this
// function will not clear the async context until the next tick's microtask,
// where it must inherit the context that scheduled that callback.
JSC_DEFINE_HOST_FUNCTION(jsCleanupLater, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    ASSERT(callFrame->argumentCount() == 0);
    auto* global = uncheckedDowncast<Zig::GlobalObject>(globalObject);
    global->asyncHooksNeedsCleanup = true;
    global->resetOnEachMicrotaskTick();
    return JSC::JSValue::encode(JSC::jsUndefined());
}

// This is called when AsyncLocalStorage is constructed.
JSC_DEFINE_HOST_FUNCTION(jsSetAsyncHooksEnabled, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    ASSERT(callFrame->argumentCount() == 1);
    globalObject->setAsyncContextTrackingEnabled(callFrame->uncheckedArgument(0).toBoolean(globalObject));
    return JSC::JSValue::encode(JSC::jsUndefined());
}

static JSValue callFSRequestFunction(JSGlobalObject* globalObject, ASCIILiteral name, MarkedArgumentBuffer& arguments)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* global = uncheckedDowncast<Zig::GlobalObject>(globalObject);
    auto module = global->internalModuleRegistry()->requireId(global, vm, InternalModuleRegistry::InternalAsyncHooksTick);
    RETURN_IF_EXCEPTION(scope, {});
    auto function = module.get(global, Identifier::fromString(vm, name));
    RETURN_IF_EXCEPTION(scope, {});
    auto result = JSC::call(global, function, jsUndefined(), arguments, "Filesystem lifecycle function must be callable"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

extern "C" EncodedJSValue Home__FSRequest__event(JSGlobalObject* globalObject, EncodedJSValue value, EncodedJSValue previous, uint8_t operation)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    MarkedArgumentBuffer arguments;
    arguments.append(JSValue::decode(value));
    if (operation == 2 || operation == 5 || operation == 6 || operation == 7) arguments.append(JSValue::decode(previous));
    if (operation == 5 || operation == 6) arguments.append(jsBoolean(operation == 6));
    auto name = operation == 0 ? "createFSRequest"_s : operation == 1 ? "enterFSRequest"_s : operation == 2 ? "leaveFSRequest"_s : operation == 3 ? "destroyFSRequest"_s : operation == 4 ? "createFSCallback"_s : operation == 8 ? "createDirectoryCloseCallback"_s : operation == 7 ? "queueFSCallback"_s : "deliverFSCallback"_s;
    auto result = callFSRequestFunction(globalObject, name, arguments);
    if (scope.exception()) {
        auto* exception = scope.exception();
        (void)scope.tryClearException();
        Bun__reportUnhandledError(globalObject, JSValue::encode(exception));
        return JSValue::encode(jsUndefined());
    }
    return JSValue::encode(result);
}

}
