#include "root.h"

#include "JavaScriptCore/Completion.h"
#include "JavaScriptCore/Exception.h"
#include "JavaScriptCore/Identifier.h"
#include "JavaScriptCore/JSCInlines.h"
#include "JavaScriptCore/JSObjectInlines.h"
#include "JavaScriptCore/ProxyObject.h"
#include "JSBuffer.h"
#include "wtf/SIMDUTF.h"
#include <wtf/Threading.h>

extern "C" void JSC__JSGlobalObject__addGc(JSC::JSGlobalObject*);
BUN_DECLARE_HOST_FUNCTION(BunObject_callback_color);

// Home's reduced C-API realm runs alongside Bun's statically linked JSC
// bindings without constructing a Bun VirtualMachine. A host callback can run
// while JSLock::willReleaseLock() drains microtasks; code entered through the
// Bun binding cone may temporarily restore the thread's previous atom-string
// table even though the raw context's API lock remains held. The next
// allocation that requests GC then hits Heap::requestCollection's mandatory
// VM/thread table identity check. Re-establish the active realm at every
// reduced-realm host boundary. JSLock still owns restoration of the entry table
// when its outermost scope exits.
extern "C" void Home__JSC__ensureCurrentAtomStringTable(JSC::JSGlobalObject* globalObject)
{
    auto& thread = WTF::Thread::currentSingleton();
    auto* table = globalObject->vm().atomStringTable();
    if (thread.atomStringTable() != table)
        thread.setCurrentAtomStringTable(table);
}

JSC_DEFINE_HOST_FUNCTION(HomeBunObject_color, (JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame))
{
    Home__JSC__ensureCurrentAtomStringTable(globalObject);
    return BunObject_callback_color(globalObject, callFrame);
}

static JSC::EncodedJSValue homeValidateBuffer(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame, bool ascii)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto value = callFrame->argument(0);
    const char* ptr = nullptr;
    size_t byteLength = 0;

    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
        if (view->isDetached()) [[unlikely]] {
            JSC::throwTypeError(globalObject, scope, "ArrayBufferView is detached"_s);
            return {};
        }
        byteLength = view->byteLength();
        ptr = reinterpret_cast<const char*>(view->vector());
    } else if (auto* arrayBuffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
        auto* impl = arrayBuffer->impl();
        if (!impl)
            return JSC::JSValue::encode(JSC::jsBoolean(true));
        if (impl->isDetached()) [[unlikely]] {
            JSC::throwTypeError(globalObject, scope, "Cannot validate on a detached buffer"_s);
            return {};
        }
        byteLength = impl->byteLength();
        ptr = reinterpret_cast<const char*>(impl->data());
    } else {
        JSC::throwTypeError(globalObject, scope, "First argument must be an ArrayBufferView"_s);
        return {};
    }

    if (byteLength == 0)
        return JSC::JSValue::encode(JSC::jsBoolean(true));
    const bool valid = ascii
        ? simdutf::validate_ascii(ptr, byteLength)
        : simdutf::validate_utf8(ptr, byteLength);
    RELEASE_AND_RETURN(scope, JSC::JSValue::encode(JSC::jsBoolean(valid)));
}

JSC_DEFINE_HOST_FUNCTION(HomeBuffer_isAscii, (JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame))
{
    return homeValidateBuffer(globalObject, callFrame, true);
}

JSC_DEFINE_HOST_FUNCTION(HomeBuffer_isUtf8, (JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame))
{
    return homeValidateBuffer(globalObject, callFrame, false);
}

static JSC::EncodedJSValue homeBufferToString(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame, WebCore::BufferEncodingType encoding)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* view = dynamicDowncast<JSC::JSArrayBufferView>(callFrame->argument(0));
    if (!view) [[unlikely]] {
        JSC::throwTypeError(globalObject, scope, "First argument must be an ArrayBufferView"_s);
        return {};
    }
    if (view->isDetached()) [[unlikely]] {
        JSC::throwTypeError(globalObject, scope, "ArrayBufferView is detached"_s);
        return {};
    }
    return WebCore::jsBufferToString(globalObject, scope, view, 0, view->byteLength(), encoding);
}

JSC_DEFINE_HOST_FUNCTION(HomeBuffer_toHex, (JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame))
{
    return homeBufferToString(globalObject, callFrame, WebCore::BufferEncodingType::hex);
}

JSC_DEFINE_HOST_FUNCTION(HomeBuffer_toLatin1, (JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame))
{
    return homeBufferToString(globalObject, callFrame, WebCore::BufferEncodingType::latin1);
}

extern "C" void Home__JSGlobalObject__addGc(JSC::JSGlobalObject* globalObject)
{
    JSC__JSGlobalObject__addGc(globalObject);

    auto& vm = globalObject->vm();
    auto identifier = JSC::Identifier::fromString(vm, "gc"_s);

    // A zero-argument host call can keep the preceding host-call result alive
    // in its caller frame. Use a real JavaScript frame and a material argument
    // so global.gc() has the same forced, synchronous liveness boundary as
    // Bun.gc(true), while retaining Node's zero-argument public API.
    auto source = JSC::makeSource("(native => function gc() { native(true); })(globalThis.gc)"_s,
        JSC::SourceOrigin(), JSC::SourceTaintedOrigin::Untainted);
    WTF::NakedPtr<JSC::Exception> exception;
    JSC::JSValue function = JSC::evaluate(globalObject, source, globalObject, exception);
    RELEASE_ASSERT(!exception);
    RELEASE_ASSERT(function.isCallable());

    globalObject->putDirect(vm, identifier, function, JSC::PropertyAttribute::DontEnum | 0);
}

// The reduced corpus realm does not instantiate Bun's native-module registry.
// Install the Buffer operations whose semantics or throughput require native
// JSC functions, including the validators' dual call/construct behavior.
extern "C" void Home__JSGlobalObject__addBufferValidators(JSC::JSGlobalObject* globalObject)
{
    Home__JSC__ensureCurrentAtomStringTable(globalObject);
    auto& vm = globalObject->vm();
    auto asciiName = JSC::Identifier::fromString(vm, "__home_bufferIsAsciiNative"_s);
    auto utf8Name = JSC::Identifier::fromString(vm, "__home_bufferIsUtf8Native"_s);
    auto hexName = JSC::Identifier::fromString(vm, "__home_bufferToHexNative"_s);
    auto latin1Name = JSC::Identifier::fromString(vm, "__home_bufferToLatin1Native"_s);
    auto* ascii = JSC::JSFunction::create(vm, globalObject, 1, "isAscii"_s,
        HomeBuffer_isAscii, JSC::ImplementationVisibility::Public,
        JSC::NoIntrinsic, HomeBuffer_isAscii);
    auto* utf8 = JSC::JSFunction::create(vm, globalObject, 1, "isUtf8"_s,
        HomeBuffer_isUtf8, JSC::ImplementationVisibility::Public,
        JSC::NoIntrinsic, HomeBuffer_isUtf8);
    auto* hex = JSC::JSFunction::create(vm, globalObject, 1, "toHex"_s,
        HomeBuffer_toHex, JSC::ImplementationVisibility::Public);
    auto* latin1 = JSC::JSFunction::create(vm, globalObject, 1, "toLatin1"_s,
        HomeBuffer_toLatin1, JSC::ImplementationVisibility::Public);
    globalObject->putDirect(vm, asciiName, ascii, JSC::PropertyAttribute::DontEnum | 0);
    globalObject->putDirect(vm, utf8Name, utf8, JSC::PropertyAttribute::DontEnum | 0);
    globalObject->putDirect(vm, hexName, hex, JSC::PropertyAttribute::DontEnum | 0);
    globalObject->putDirect(vm, latin1Name, latin1, JSC::PropertyAttribute::DontEnum | 0);
}

// Bun's production global installs this callback through GeneratedBunObject.
// Home's reduced C-API realms deliberately use a plain JSGlobalObject, so bind
// the exact same Zig callback onto their JavaScript-created `Bun` namespace.
// This keeps unit and corpus realms on the production CSS parser/formatter
// instead of maintaining a second JavaScript color implementation.
extern "C" void Home__BunObject__installColor(JSC::JSGlobalObject* globalObject)
{
    auto& vm = globalObject->vm();
    auto bunIdentifier = JSC::Identifier::fromString(vm, "Bun"_s);
    auto bunValue = globalObject->get(globalObject, bunIdentifier);
    if (!bunValue.isObject())
        return;

    auto* bunObject = bunValue.getObject();
    // The corpus harness wraps Bun to observe ownKeys reification. Direct-slot
    // insertion is invalid on a ProxyObject because it has no ordinary object
    // storage; install on the underlying namespace just as the proxy's default
    // [[Set]] forwarding would.
    if (bunObject->type() == JSC::ProxyObjectType)
        bunObject = uncheckedDowncast<JSC::ProxyObject>(bunObject)->target();
    bunObject->putDirectNativeFunction(
        vm,
        globalObject,
        JSC::Identifier::fromString(vm, "color"_s),
        2,
        HomeBunObject_color,
        JSC::ImplementationVisibility::Public,
        JSC::NoIntrinsic,
        JSC::PropertyAttribute::DontDelete | 0);
}
