#include "root.h"

#include "JavaScriptCore/Completion.h"
#include "JavaScriptCore/Exception.h"
#include "JavaScriptCore/Identifier.h"
#include "JavaScriptCore/JSCInlines.h"

extern "C" void JSC__JSGlobalObject__addGc(JSC::JSGlobalObject*);

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
