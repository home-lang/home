#pragma once

#include "JSDOMGlobalObject.h"
#include "JSDOMWrapperCache.h"
#include "JSWebSocket.h"
#include "ScriptExecutionContext.h"
#include <JavaScriptCore/InternalFieldTuple.h>
#include <JavaScriptCore/PrivateName.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/Scope.h>

namespace WebCore::WebSocketAsyncContext {

inline JSC::Identifier contextName(JSC::VM& vm)
{
    static NeverDestroyed<JSC::PrivateName> name(JSC::PrivateName::PrivateSymbol, String::fromUTF8("HomeWebSocketAsyncContext"));
    return JSC::Identifier::fromUid(vm, &name.get().uid());
}

inline void capture(JSWebSocket& wrapper, JSC::VM& vm)
{
    // A private property is traced with the wrapper and cannot be observed or
    // changed by JavaScript. No native root may outlive the socket's wrapper.
    auto context = wrapper.globalObject()->m_asyncContextData.get()->getInternalField(0);
    wrapper.putDirect(vm, contextName(vm), context);
}

template<typename EventType>
inline void dispatch(WebSocket& socket, Ref<EventType>&& event)
{
    auto* context = socket.scriptExecutionContext();
    if (!context)
        return;
    auto* global = uncheckedDowncast<JSDOMGlobalObject>(context->jsGlobalObject());
    auto* wrapper = getCachedWrapper(global->world(), socket);
    if (!wrapper) {
        socket.dispatchEvent(event);
        return;
    }
    auto& vm = global->vm();
    auto captured = wrapper->getDirect(vm, contextName(vm));
    if (captured.isEmpty()) {
        socket.dispatchEvent(event);
        return;
    }
    JSC::EnsureStillAliveScope protectWrapper(wrapper);
    auto* data = global->m_asyncContextData.get();
    JSC::EnsureStillAliveScope previous(data->getInternalField(0));
    data->putInternalField(vm, 0, captured);
    auto restore = makeScopeExit([&] {
        data->putInternalField(vm, 0, previous.value());
    });
    // Only native delivery uses the resource context. A user's synchronous
    // dispatchEvent still runs in that caller's current context.
    socket.dispatchEvent(event);
}

}
