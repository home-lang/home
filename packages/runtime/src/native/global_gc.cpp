#include "root.h"

#include "JavaScriptCore/Completion.h"
#include "JavaScriptCore/Exception.h"
#include "JavaScriptCore/Identifier.h"
#include "JavaScriptCore/JSCInlines.h"
#include <wtf/Threading.h>

extern "C" void JSC__JSGlobalObject__addGc(JSC::JSGlobalObject*);

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
