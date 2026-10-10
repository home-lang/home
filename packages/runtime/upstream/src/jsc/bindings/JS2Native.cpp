#include "root.h"
#include "JS2Native.h"

#include <JavaScriptCore/BuiltinUtils.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/ObjectConstructor.h>

#include "ZigGlobalObject.h"

#include "GeneratedJS2Native.h"
#include "wtf/Assertions.h"

extern "C" JSC::EncodedJSValue ByteBlob__JSReadableStreamSource__load(JSC::JSGlobalObject* global);
extern "C" JSC::EncodedJSValue FileReader__JSReadableStreamSource__load(JSC::JSGlobalObject* global);
extern "C" JSC::EncodedJSValue ByteStream__JSReadableStreamSource__load(JSC::JSGlobalObject* global);

extern "C" void* Home__VirtualMachine__socketLoop(void* vm);
#if !OS(WINDOWS)
extern "C" void Home__loop_utilization(void* loop, double* idle, double* active);
#endif
namespace Home {
JSC_DEFINE_HOST_FUNCTION(readLoopUtilization, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    UNUSED_PARAM(callFrame);
#if OS(WINDOWS)
    JSC::throwTypeError(globalObject, scope, "Event-loop utilization measurement requires libuv metrics support"_s);
    return {};
#else
    double idle = 0, active = 0;
    Home__loop_utilization(Home__VirtualMachine__socketLoop(bunVM(globalObject)), &idle, &active);
    auto* result = JSC::constructEmptyObject(globalObject);
    result->putDirect(vm, JSC::Identifier::fromString(vm, "idle"_s), JSC::jsNumber(idle));
    result->putDirect(vm, JSC::Identifier::fromString(vm, "active"_s), JSC::jsNumber(active));
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(result);
#endif
}
static JSC::JSValue createPerformanceBinding(Zig::GlobalObject* globalObject)
{
    return JSC::JSFunction::create(globalObject->vm(), globalObject, 0, "readLoopUtilization"_s, readLoopUtilization, JSC::ImplementationVisibility::Public);
}
}

namespace Bun {
namespace JS2Native {

// This is the implementation of the generated $lazy
JSC_DEFINE_HOST_FUNCTION(jsDollarLazy, (JSC::JSGlobalObject * lexicalGlobalObject, JSC::CallFrame* callFrame))
{
    JSC::JSValue target = callFrame->uncheckedArgument(0);

#if ASSERT_ENABLED
    ASSERT_WITH_MESSAGE(target.isInt32(), "In call to $lazy: expected Int32, got %s", target.toWTFString(lexicalGlobalObject).utf8().data());
#endif

    int id = target.asInt32();
    RELEASE_ASSERT(
        id <= JS2NATIVE_COUNT && id >= 0,
        "In call to $lazy, got invalid id '%d'. This is a bug in Bun's JS2Native code generator.",
        id);
    Zig::GlobalObject* ptr = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    if (id == JS2NATIVE_COUNT) return JSValue::encode(Home::createPerformanceBinding(ptr));
    return JSValue::encode(JS2NativeGenerated::callJS2Native(id, ptr));
}

} // namespace JS2Native
} // namespace Bun
