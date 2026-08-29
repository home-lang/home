/*
 * Copyright (C) 2008 Apple Inc. All Rights Reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include "config.h"
#include "MessagePort.h"

#include "BunClientData.h"
#include "EventNames.h"
#include "HomeMessagePortLifecycle.h"
#include "MessageEvent.h"
#include "MessagePortPipe.h"
#include "MessageWithMessagePorts.h"
#include "StructuredSerializeOptions.h"
#include "WebCoreOpaqueRoot.h"
#include <wtf/TZoneMallocInlines.h>

extern "C" void Bun__eventLoop__incrementRefConcurrently(void* bunVM, int delta);

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(MessagePort);

Ref<MessagePort> MessagePort::create(ScriptExecutionContext& context, Ref<MessagePortPipe>&& pipe, uint8_t side)
{
    auto port = adoptRef(*new MessagePort(context, WTF::move(pipe), side));
    // Registration is distinct from start(): an unstarted port still needs
    // peer-close notifications, while its message inbox must stay buffered.
    port->m_pipe->attach(side, context.identifier(), ThreadSafeWeakPtr<MessagePort> { port.get() });
    return port;
}

MessagePort::MessagePort(ScriptExecutionContext& context, Ref<MessagePortPipe>&& pipe, uint8_t side)
    : ContextDestructionObserver(&context)
    , m_pipe(WTF::move(pipe))
    , m_side(side)
{
    // The WeakPtrFactory must be initialized on the owning thread.
    initializeWeakPtrFactory();
}

MessagePort::~MessagePort()
{
    if (!m_isDetached || m_started) {
        m_pipe->detach(m_side);
        m_pipe->close(m_side);
    }
}

ExceptionOr<void> MessagePort::postMessage(JSC::JSGlobalObject& state, JSC::JSValue messageValue, StructuredSerializeOptions&& options)
{
    Vector<RefPtr<MessagePort>> ports;
    auto messageData = SerializedScriptValue::create(state, messageValue, WTF::move(options.transfer), ports, SerializationForStorage::No, SerializationContext::WorkerPostMessage);
    if (messageData.hasException())
        return messageData.releaseException();

    Vector<TransferredMessagePort> transferredPorts;
    if (!ports.isEmpty()) {
        // A live sender may not transfer its own peer. An inactive sender
        // still consumes transfer lists, including a still-active former peer.
        for (auto& port : ports) {
            if (port.get() == this || (isEntangled() && port->pipe() == m_pipe.ptr()))
                return Exception { DataCloneError };
        }
        auto disentangled = MessagePort::disentanglePorts(WTF::move(ports));
        if (disentangled.hasException())
            return disentangled.releaseException();
        transferredPorts = disentangled.releaseReturnValue();
    }

    // Transfer-list processing still consumes transferred resources when the
    // sending wrapper is closed. The temporary endpoints then close as orphans.
    if (!isEntangled())
        return {};

    MessageWithMessagePorts message { messageData.releaseReturnValue(), WTF::move(transferredPorts) };
    if (!WorkerParentPort::send(m_pipe.get(), m_side, WTF::move(message)))
        m_pipe->send(m_side, WTF::move(message));
    return {};
}

void MessagePort::start()
{
    if (m_started || !isEntangled())
        return;
    m_started = true;

    auto* context = scriptExecutionContext();
    ASSERT(context);
    // From the pipe's point of view "attached" means "ready to have drains
    // scheduled on my behalf" — that is exactly what start() promises.
    m_pipe->attach(m_side, context->identifier(), ThreadSafeWeakPtr<MessagePort> { *this });
}

void MessagePort::close()
{
    if (m_isDetached)
        return;
    // Once detached, started distinguishes a pending local close from a
    // transferred-away wrapper. Only the former can synchronously consume its
    // inbox before close completion; both retain pending close notifications.
    m_started = true;
    m_isDetached = true;

    // Closed stops outgoing sends/transfer immediately, but the pipe retains
    // the local inbox until its asynchronous close event is ready to dispatch.
    m_pipe->close(m_side);

    // Release the self-reference taken by jsRef() (set when .onmessage is
    // assigned or .ref() is called from JS). The JS .close() binding calls
    // jsUnref() first, so m_hasRef is already false on that path; we only
    // reach this branch when close() runs without a preceding jsUnref() —
    // most importantly from contextDestroyed() during Worker teardown.
    // Without this, the self-ref pins the MessagePort past the JS wrapper
    // sweep and it leaks forever.
    if (m_hasRef) {
        m_hasRef = false;
        if (auto* context = scriptExecutionContext())
            context->unrefEventLoop();
        deref();
    }
}

TransferredMessagePort MessagePort::disentangle()
{
    ASSERT(isEntangled());

    // Retain listeners until the old wrapper's asynchronous close event.
    // It remains a destruction observer so a dying context can instead
    // clear listeners and release their event-loop refs without running JS.

    // Release the self-reference taken by jsRef() on the sending side. After
    // transfer this object is inert (the receiving side gets a fresh
    // MessagePort for the same pipe endpoint). Its pending close retains the
    // wrapper, but must not keep the sending event loop referenced.
    // The caller (disentanglePorts) holds a RefPtr, so deref() is safe.
    if (m_hasRef) {
        m_hasRef = false;
        if (auto* context = scriptExecutionContext())
            context->unrefEventLoop();
        deref();
    }

    // Hand the pipe endpoint to its next owner. Messages that arrive while
    // in transit buffer in the pipe; the receiving context's entangle()
    // re-attaches and flushes them. We keep our own ref to the pipe so the
    // GC thread can always dereference it — our side is detached, so all
    // further operations on it are no-ops.
    m_pipe->detach(m_side);
    m_started = false;
    m_isDetached = true;

    if (auto* context = scriptExecutionContext()) {
        context->postTask([port = Ref { *this }](ScriptExecutionContext&) {
            if (!port->scriptExecutionContext())
                return;
            auto event = Event::create(eventNames().closeEvent, Event::CanBubble::No, Event::IsCancelable::No);
            port->dispatchEvent(event);
        });
    }

    return TransferredMessagePort { m_pipe.copyRef(), m_side };
}

Ref<MessagePort> MessagePort::entangle(ScriptExecutionContext& context, TransferredMessagePort&& transferred)
{
    ASSERT(transferred.pipe);
    auto port = MessagePort::create(context, transferred.pipe.releaseNonNull(), transferred.side);
    // Only transferred ports ref the event loop on message-listener
    // add/remove; ports that were never transferred (both ends of a local
    // MessageChannel) don't hold the process open.
    port->onDidChangeListener = &MessagePort::onDidChangeListenerImpl;
    return port;
}

void MessagePort::dispatchOneMessage(ScriptExecutionContext& context, MessageWithMessagePorts&& message)
{
    if (m_isDetached || !context.globalObject())
        return;

    auto* globalObject = defaultGlobalObject(context.globalObject());
    Ref vm = globalObject->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (Zig::GlobalObject::scriptExecutionStatus(globalObject, globalObject) != ScriptExecutionStatus::Running)
        return;

    auto ports = MessagePort::entanglePorts(context, WTF::move(message.transferredPorts));
    if (scope.exception()) [[unlikely]] {
        RELEASE_ASSERT(vm->hasPendingTerminationException());
        return;
    }

    auto event = MessageEvent::create(*context.jsGlobalObject(), message.message.releaseNonNull(), {}, {}, {}, WTF::move(ports));
    dispatchEvent(event.event);
    WorkerParentPort::forwardGlobalEvent(*this, context, event.event.get());
}

JSValue MessagePort::tryTakeMessage(JSGlobalObject* lexicalGlobalObject)
{
    auto& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    const uint64_t state = m_pipe->state(m_side);
    const bool pendingLocalClose = m_isDetached && m_started
        && (state & MessagePortPipe::Closed) && !(state & MessagePortLifecycle::CloseDispatched);
    if (!isEntangled() && !pendingLocalClose)
        return jsUndefined();

    auto* context = scriptExecutionContext();
    if (!context)
        return jsUndefined();

    auto message = m_pipe->takeOne(m_side);
    if (!message)
        return jsUndefined();

    auto ports = MessagePort::entanglePorts(*context, WTF::move(message->transferredPorts));
    auto value = message->message.releaseNonNull()->deserialize(*lexicalGlobalObject, lexicalGlobalObject, WTF::move(ports), SerializationErrorMode::Throwing);
    RETURN_IF_EXCEPTION(scope, {});
    if (!value) [[unlikely]] {
        throwTypeError(lexicalGlobalObject, scope, "Failed to deserialize MessagePort message"_s);
        return {};
    }
    // Presence is independent of the serialized value. In particular, a real
    // undefined message must be distinguishable from an empty receive queue.
    auto* result = constructEmptyObject(lexicalGlobalObject);
    RETURN_IF_EXCEPTION(scope, {});
    result->putDirect(vm, vm.propertyNames->message, value);
    RELEASE_AND_RETURN(scope, result);
}

void MessagePort::dispatchEvent(Event& event)
{
    // Only a native trusted close event can finalize a detached wrapper.
    // dispatchEventForBindings always makes user-provided events untrusted.
    if (event.isTrusted() && event.type() == eventNames().closeEvent) {
        Ref protectedThis { *this };
        if (m_isDetached && !scriptExecutionContext())
            return;
        close();
        if (auto* context = scriptExecutionContext(); context && context->globalObject() && !context->isJSExecutionForbidden()) {
            auto* globalObject = defaultGlobalObject(context->globalObject());
            // Worker teardown can clear JSC's termination flag while Home's
            // VM is still stopped. Match ordinary message dispatch's gate.
            if (Zig::GlobalObject::scriptExecutionStatus(globalObject, globalObject) == ScriptExecutionStatus::Running)
                EventTarget::dispatchEvent(event);
        }
        removeAllEventListeners();
        m_hasMessageEventListener = false;
        m_started = false;
        observeContext(nullptr);
        return;
    }
    if (m_isDetached)
        return;
    EventTarget::dispatchEvent(event);
}

void MessagePort::contextDestroyed()
{
    // close() releases the jsRef() self-reference, which may be the last
    // strong ref if the JS wrapper was already swept. Protect across the
    // call so we can cleanly detach from the dying ScriptExecutionContext
    // first — otherwise ~ContextDestructionObserver() would call back into
    // it while it is mid-destruction.
    Ref protectedThis { *this };
    // A dying wrapper has no pending receive window. Unregister it before
    // closing so the pipe discards its inbox even if local close was pending.
    if (!m_isDetached || m_started) {
        m_pipe->detach(m_side);
        m_pipe->close(m_side);
    }
    close();
    // No JS may run during context destruction, including a queued close for
    // a transferred-away wrapper. Clear refs while the context still exists.
    removeAllEventListeners();
    m_hasMessageEventListener = false;
    m_started = false;
    ContextDestructionObserver::contextDestroyed();
}

bool MessagePort::hasPendingActivity() const
{
    // Called from the GC thread concurrently with the mutator; must be
    // lockless. m_pipe is a Ref<> held for the port's whole lifetime, so
    // the dereference is always safe; state() and isOtherSideOpen() are
    // atomic loads. The plain bool reads can observe stale values but
    // cannot crash — at worst the wrapper is collected one cycle early
    // or late, which is the same tolerance as before this refactor.
    if (!scriptExecutionContext())
        return false;
    const uint64_t s = m_pipe->state(m_side);
    // A queued native close must keep its JS listener/wrapper alive even if
    // there is no message listener. Never touch another context's weak port.
    if ((s & MessagePortPipe::Closed) && (s & MessagePortPipe::DrainScheduled))
        return true;
    if ((s & MessagePortLifecycle::PeerClosed) && (s & MessagePortPipe::DrainScheduled)
        && !(s & MessagePortLifecycle::CloseDispatched))
        return true;
    if (m_isDetached)
        return true; // its context is retained only until close dispatch/teardown
    if (!m_hasMessageEventListener)
        return false;

    // Keep alive if there are messages already queued for us, or the peer
    // is still open and could send more.
    return MessagePortPipe::queuedCount(s) > 0 || m_pipe->isOtherSideOpen(m_side);
}

ExceptionOr<Vector<TransferredMessagePort>> MessagePort::disentanglePorts(Vector<RefPtr<MessagePort>>&& ports)
{
    if (ports.isEmpty())
        return Vector<TransferredMessagePort> {};

    HashSet<MessagePort*> seen;
    for (auto& port : ports) {
        if (!port || !port->isEntangled() || !seen.add(port.get()).isNewEntry)
            return Exception { DataCloneError };
    }

    return WTF::map(ports, [](auto& port) {
        return port->disentangle();
    });
}

Vector<RefPtr<MessagePort>> MessagePort::entanglePorts(ScriptExecutionContext& context, Vector<TransferredMessagePort>&& transferred)
{
    if (transferred.isEmpty())
        return {};

    return WTF::map(WTF::move(transferred), [&](TransferredMessagePort&& port) -> RefPtr<MessagePort> {
        return MessagePort::entangle(context, WTF::move(port));
    });
}

void MessagePort::onDidChangeListenerImpl(EventTarget& self, const AtomString& eventType, OnDidChangeListenerKind kind)
{
    if (eventType != eventNames().messageEvent)
        return;

    auto& port = static_cast<MessagePort&>(self);
    auto* context = port.scriptExecutionContext();
    switch (kind) {
    case Add:
        if (port.m_messageEventCount == 0 && context)
            port.jsRef(context->jsGlobalObject());
        port.m_messageEventCount++;
        break;
    case Remove:
        port.m_messageEventCount--;
        if (port.m_messageEventCount == 0 && context)
            port.jsUnref(context->jsGlobalObject());
        break;
    case Clear:
        if (port.m_messageEventCount > 0 && context)
            port.jsUnref(context->jsGlobalObject());
        port.m_messageEventCount = 0;
        break;
    }
}

bool MessagePort::addEventListener(const AtomString& eventType, Ref<EventListener>&& listener, const AddEventListenerOptions& options)
{
    if (eventType == eventNames().messageEvent) {
        start();
        m_hasMessageEventListener = true;
    }
    return EventTarget::addEventListener(eventType, WTF::move(listener), options);
}

bool MessagePort::removeEventListener(const AtomString& eventType, EventListener& listener, const EventListenerOptions& options)
{
    auto result = EventTarget::removeEventListener(eventType, listener, options);
    if (!hasEventListeners(eventNames().messageEvent))
        m_hasMessageEventListener = false;
    return result;
}

WebCoreOpaqueRoot root(MessagePort* port)
{
    return WebCoreOpaqueRoot { port };
}

void MessagePort::jsRef(JSGlobalObject* lexicalGlobalObject)
{
    // A closed or transferred-away port can never receive messages again, so
    // taking a self-ref (and an event-loop ref) here would only leak:
    // close()/disentangle() have already run and nothing will ever release a
    // ref taken afterwards.
    if (!isEntangled())
        return;

    if (!m_hasRef) {
        m_hasRef = true;
        ref();
        Bun__eventLoop__incrementRefConcurrently(WebCore::clientData(lexicalGlobalObject->vm())->bunVM, 1);
    }
}

void MessagePort::jsUnref(JSGlobalObject* lexicalGlobalObject)
{
    if (m_hasRef) {
        m_hasRef = false;
        deref();
        Bun__eventLoop__incrementRefConcurrently(WebCore::clientData(lexicalGlobalObject->vm())->bunVM, -1);
    }
}

} // namespace WebCore
