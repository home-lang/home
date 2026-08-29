#include "config.h"
#include "MessagePort.h"

// When the verification harness reverts src/ to origin/main, this file and
// MessagePortPipe.h survive as new untracked files but MessagePort.h /
// TransferredMessagePort.h revert to their identifier-based predecessors.
// The body below references symbols that only exist on the pipe-backed
// MessagePort.h (dispatchOneMessage, the struct TransferredMessagePort), so
// compile it only when that header is present.
#if BUN_MESSAGEPORT_USES_PIPE

#include "MessagePortPipe.h"
#include "Event.h"
#include "EventNames.h"
#include "HomeMessagePortLifecycle.h"
#include "ScriptExecutionContext.h"
#include <wtf/Locker.h>

namespace WebCore {

using namespace MessagePortLifecycle;

static_assert(!((PeerClosed | CloseDispatched) & (MessagePortPipe::Closed | MessagePortPipe::DrainScheduled | MessagePortPipe::Attached)));
static_assert((PeerClosed | CloseDispatched) < MessagePortPipe::QueuedOne);

static bool homePortDrainReady(uint64_t state)
{
    if (state & CloseDispatched)
        return false;
    return (state & MessagePortPipe::Closed)
        || ((state & PeerClosed) && !MessagePortPipe::queuedCount(state))
        || ((state & MessagePortPipe::Attached) && MessagePortPipe::queuedCount(state));
}

MessagePortPipe::~MessagePortPipe() = default;

// Defined here (not in TransferredMessagePort.h) to break the header cycle
// MessagePortPipe.h → MessageWithMessagePorts.h → TransferredMessagePort.h.
TransferredMessagePort::~TransferredMessagePort()
{
    // If this endpoint is destroyed while still owning the pipe side (never
    // handed off to a new MessagePort via entangle()), the side is orphaned;
    // mark it Closed so the peer's hasPendingActivity() can return false.
    if (pipe)
        pipe->close(side);
}

TransferredMessagePort& TransferredMessagePort::operator=(TransferredMessagePort&& other)
{
    if (this != &other) {
        if (pipe)
            pipe->close(side);
        pipe = WTF::move(other.pipe);
        side = other.side;
    }
    return *this;
}

void MessagePortPipe::send(uint8_t fromSide, MessageWithMessagePorts&& message)
{
    ASSERT(fromSide < 2);
    if (state(fromSide) & Closed)
        return;
    auto& dst = m_sides[1 - fromSide];

    ScriptExecutionContextIdentifier wakeCtx = 0;
    {
        Locker locker { dst.lock };
        uint64_t s = dst.state.load(std::memory_order_relaxed);
        // Local close stops outgoing sends immediately, but incoming data is
        // still synchronously receivable until that endpoint finishes closing.
        if ((s & CloseDispatched) || ((s & Closed) && !dst.ctxId))
            return;

        dst.inbox.append(WTF::move(message));

        uint64_t ns = s + QueuedOne;
        if ((s & Attached) && !(s & DrainScheduled)) {
            ns |= DrainScheduled;
            wakeCtx = dst.ctxId;
        }
        dst.state.store(ns, std::memory_order_release);
    }

    if (wakeCtx)
        scheduleDrain(1 - fromSide, wakeCtx);
}

void MessagePortPipe::scheduleDrain(uint8_t side, ScriptExecutionContextIdentifier ctxId)
{
    // The posted task holds a strong ref to the pipe so it can't be destroyed
    // while a wakeup is in flight. The task captures the ctxId it was posted
    // to so drainAndDispatch can detect if the side moved to a different
    // context before the task ran.
    ThreadSafeWeakPtr<MessagePort> expectedPort;
    {
        Locker locker { m_sides[side].lock };
        if (m_sides[side].ctxId != ctxId)
            return;
        expectedPort = m_sides[side].port;
    }
    // Teardown GC can destroy ports before the context leaves the global map.
    // Its event loop has already stopped: enqueueing here would strand the
    // task's strong pipe ref. Inspect VM state only on the owning thread, and
    // outside the contexts-map lock (releasing captures may itself close ports).
    bool posted = ScriptExecutionContext::ensureOnContextThread(ctxId, [pipe = Ref { *this }, side, ctxId, expectedPort](ScriptExecutionContext& context) {
        RefPtr<MessagePort> currentPort;
        RefPtr<MessagePort> scheduledPort;
        {
            Locker locker { pipe->m_sides[side].lock };
            if (pipe->m_sides[side].ctxId != ctxId)
                return;
            currentPort = pipe->m_sides[side].port.get();
            scheduledPort = expectedPort.get();
        }
        if (currentPort != scheduledPort)
            return;
        auto* globalObject = context.globalObject() ? defaultGlobalObject(context.globalObject()) : nullptr;
        if (!globalObject || context.isJSExecutionForbidden()
            || Zig::GlobalObject::scriptExecutionStatus(globalObject, globalObject) != ScriptExecutionStatus::Running) {
            Locker locker { pipe->m_sides[side].lock };
            if (pipe->m_sides[side].ctxId == ctxId)
                pipe->m_sides[side].state.fetch_and(~uint64_t(DrainScheduled), std::memory_order_acq_rel);
            return;
        }
        // ensureOnContextThread may run inline for a local close. Delivery
        // must remain asynchronous, including when both endpoints are local.
        context.postTask([pipe = pipe.copyRef(), side, ctxId, expectedPort](ScriptExecutionContext&) {
            RefPtr<MessagePort> currentPort;
            RefPtr<MessagePort> scheduledPort;
            {
                Locker locker { pipe->m_sides[side].lock };
                if (pipe->m_sides[side].ctxId != ctxId)
                    return;
                currentPort = pipe->m_sides[side].port.get();
                scheduledPort = expectedPort.get();
            }
            // A last strong ref can run MessagePort::~MessagePort -> close().
            // Never release these snapshots while the pipe-side lock is held.
            if (currentPort != scheduledPort)
                return;
            pipe->drainAndDispatch(side, ctxId);
        });
    });
    if (!posted) {
        // Context already torn down. Drop DrainScheduled so a future
        // attach() to a new context can reschedule.
        Locker locker { m_sides[side].lock };
        if (m_sides[side].ctxId == ctxId)
            m_sides[side].state.fetch_and(~uint64_t(DrainScheduled), std::memory_order_acq_rel);
    }
}

void MessagePortPipe::drainAndDispatch(uint8_t side, ScriptExecutionContextIdentifier expectedCtx)
{
    // Mirrors Node's MessagePort::OnMessage (src/node_messaging.cc): one
    // drain task processes the whole inbox in a loop, draining microtasks
    // between each delivery so queueMicrotask/Promise callbacks observe
    // messages one at a time, but without a separate posted task per
    // message. The per-invocation limit is max(initial queue size, 1000)
    // — enough to amortize the uv_async-style reschedule cost, capped so a
    // fast sender can't starve the event loop indefinitely.
    //
    // Messages are popped one at a time under the lock, so if the handler
    // transfers this port (pipe->detach clears `s.port`/`Attached`) the
    // remaining inbox stays buffered for the new owner.
    auto& s = m_sides[side];

    RefPtr<MessagePort> port;
    size_t limit;
    {
        Locker locker { s.lock };
        // This task was posted to `expectedCtx` (and is running there). If
        // the side has since been detached and re-attached to a different
        // context, s.port now belongs to a different thread — dispatching
        // from here would be cross-thread JS. Leave everything alone: the
        // new owner's attach() has (or will have) scheduled its own drain.
        if (s.ctxId != expectedCtx)
            return;
        port = s.port.get();
        uint64_t st = s.state.load(std::memory_order_relaxed);
        if (!port || !homePortDrainReady(st)) {
            s.state.store(st & ~DrainScheduled, std::memory_order_release);
            return;
        }
        limit = std::max<size_t>(s.inbox.size(), 1000);
    }

    auto* context = port->scriptExecutionContext();
    if (!context || !context->globalObject()) {
        Locker locker { s.lock };
        s.state.fetch_and(~uint64_t(DrainScheduled), std::memory_order_acq_rel);
        return;
    }
    auto* globalObject = defaultGlobalObject(context->globalObject());

    ScriptExecutionContextIdentifier rescheduleCtx = 0;
    while (true) {
        std::optional<MessageWithMessagePorts> message;
        RefPtr<MessagePort> currentPort;
        bool dispatchClose = false;
        {
            Locker locker { s.lock };
            // Re-check each iteration: the handler (or a concurrent thread)
            // may have closed or transferred this port. A same-context
            // detach+re-attach restores ctxId but installs a different
            // MessagePort, so compare port identity too — dispatching to
            // the stale (now m_isDetached) `port` would silently drop.
            // The new owner's attach() scheduled its own drain; leave the
            // inbox for that.
            if (s.ctxId != expectedCtx)
                break;
            currentPort = s.port.get();
            if (currentPort != port)
                break;
            uint64_t st = s.state.load(std::memory_order_relaxed);
            if (!homePortDrainReady(st)) {
                s.state.store(st & ~DrainScheduled, std::memory_order_release);
                break;
            }
            if ((st & Closed) || ((st & PeerClosed) && s.inbox.isEmpty())) {
                // A close is a control marker after the peer's accepted
                // messages, not a reason to discard that inbox. Explicit
                // local close instead ends its pending receive window here.
                dispatchClose = true;
            } else {
                if (limit-- == 0) {
                    // Yield to the rest of the event loop; DrainScheduled stays
                    // set so concurrent sends don't double-schedule.
                    rescheduleCtx = s.ctxId;
                    break;
                }
                message = s.inbox.takeFirst();
                s.state.store(st - QueuedOne, std::memory_order_release);
            }
        }

        if (dispatchClose) {
            // Keep the pipe's atomic pending protection until the wrapper
            // has its own pending-close state. GC can run concurrently here,
            // as well as during the subsequent Event allocation.
            port->close();
            {
                Locker locker { s.lock };
                const uint64_t st = s.state.load(std::memory_order_relaxed);
                s.state.store((st | Closed | CloseDispatched) & ~uint64_t(Attached), std::memory_order_release);
            }
            // End the pending receive window and iteratively discard any
            // remaining local data before callbacks, without clearing the
            // atomic GC protection until the event has been allocated.
            close(side);
            auto event = Event::create(eventNames().closeEvent, Event::CanBubble::No, Event::IsCancelable::No);
            port->dispatchEvent(event);
            {
                Locker locker { s.lock };
                s.state.fetch_and(~uint64_t(DrainScheduled), std::memory_order_acq_rel);
            }
            break;
        }

        port->dispatchOneMessage(*context, WTF::move(*message));

        // Node's MakeCallback wraps each emit in an InternalCallbackScope,
        // which drains nextTick + microtasks on exit; match that so
        // queueMicrotask(cb) inside onmessage runs before the next message.
        if (globalObject->drainMicrotasks())
            break; // termination pending
    }

    if (rescheduleCtx)
        scheduleDrain(side, rescheduleCtx);
}

std::optional<MessageWithMessagePorts> MessagePortPipe::takeOne(uint8_t side)
{
    ASSERT(side < 2);
    auto& s = m_sides[side];
    ScriptExecutionContextIdentifier wakeCtx = 0;
    {
        Locker locker { s.lock };
        uint64_t st = s.state.load(std::memory_order_relaxed);
        if (!s.inbox.isEmpty()) {
            s.state.store(st - QueuedOne, std::memory_order_release);
            return s.inbox.takeFirst();
        }
        // Like Node's close marker, a synchronous read beyond the final data
        // message wakes closure even if this receiver has never started.
        if (s.ctxId && homePortDrainReady(st) && !(st & DrainScheduled)) {
            s.state.store(st | DrainScheduled, std::memory_order_release);
            wakeCtx = s.ctxId;
        }
    }
    if (wakeCtx)
        scheduleDrain(side, wakeCtx);
    return std::nullopt;
}

void MessagePortPipe::attach(uint8_t side, ScriptExecutionContextIdentifier ctxId, ThreadSafeWeakPtr<MessagePort> port)
{
    ASSERT(side < 2);
    auto& s = m_sides[side];
    // Called only on the receiver's thread. Registration exists before
    // start(), but only a started port can consume ordinary queued messages.
    auto protectedPort = port.get();
    const bool started = protectedPort && protectedPort->started();
    ScriptExecutionContextIdentifier wakeCtx = 0;
    {
        Locker locker { s.lock };
        s.ctxId = ctxId;
        s.port = WTF::move(port);
        uint64_t st = s.state.load(std::memory_order_relaxed);
        uint64_t ns = started ? st | Attached : st & ~Attached;
        // Closed is terminal; reattachment must never reopen an endpoint.
        if ((homePortDrainReady(ns) || ((ns & PeerClosed) && !(ns & CloseDispatched))) && !(st & DrainScheduled)) {
            ns |= DrainScheduled;
            wakeCtx = ctxId;
        }
        s.state.store(ns, std::memory_order_release);
    }
    if (wakeCtx)
        scheduleDrain(side, wakeCtx);
}

void MessagePortPipe::detach(uint8_t side)
{
    ASSERT(side < 2);
    auto& s = m_sides[side];
    Locker locker { s.lock };
    s.ctxId = 0;
    s.port = nullptr;
    // Drop Attached and DrainScheduled. A drain task already in flight on
    // the old context can't be recalled, but it captured the old ctxId and
    // drainAndDispatch()'s s.ctxId != expectedCtx check makes it a no-op —
    // even if a new owner attach()es to a different context before it runs.
    // Messages remain queued for the next owner.
    s.state.fetch_and(~uint64_t(Attached | DrainScheduled), std::memory_order_acq_rel);
}

void MessagePortPipe::close(uint8_t side)
{
    ASSERT(side < 2);

    // Dropped messages can carry TransferredMessagePorts, whose destructor
    // calls close() on their pipe. Letting those destruct naturally recurses
    // (close -> ~Deque -> ~TransferredMessagePort -> close -> ...), so a long
    // chain of nested transferred ports overflows the native stack. Drain the
    // cascade iteratively instead: steal transferred pipes from each batch of
    // dropped messages into a stack-local worklist and close them in a loop.
    Vector<std::pair<RefPtr<MessagePortPipe>, uint8_t>> worklist;
    worklist.append({ this, side });

    while (!worklist.isEmpty()) {
        auto [pipe, sd] = worklist.takeLast();
        auto& s = pipe->m_sides[sd];

        Deque<MessageWithMessagePorts> dropped;
        ScriptExecutionContextIdentifier localWake = 0;
        bool notifyPeer = false;
        {
            Locker locker { s.lock };
            const uint64_t st = s.state.load(std::memory_order_relaxed);
            notifyPeer = !(st & Closed);
            const bool discardInbox = !s.ctxId || (st & CloseDispatched);
            if (!notifyPeer && !discardInbox)
                continue;
            // An attached wrapper keeps its inbox available to synchronous
            // receive until close completion. Orphaned/tearing-down endpoints
            // have no receive window and must release nested transfers now.
            uint64_t ns = (st | Closed) & ~uint64_t(Attached);
            if (discardInbox) {
                dropped = std::exchange(s.inbox, {});
                ns &= QueuedOne - 1;
            }
            if (s.ctxId && !(ns & (DrainScheduled | CloseDispatched))) {
                ns |= DrainScheduled;
                localWake = s.ctxId;
            }
            s.state.store(ns, std::memory_order_release);
        }

        ScriptExecutionContextIdentifier peerWake = 0;
        if (notifyPeer) {
            auto& peer = pipe->m_sides[1 - sd];
            Locker locker { peer.lock };
            uint64_t ns = peer.state.load(std::memory_order_relaxed) | PeerClosed;
            // Post the peer-close notification once even for an unstarted
            // receiver with data. If data is still unread when that task
            // arrives, it stalls; a later start/empty synchronous read wakes
            // it again. A synchronous pop before arrival must not lose it.
            if (peer.ctxId && !(ns & (DrainScheduled | CloseDispatched))) {
                ns |= DrainScheduled;
                peerWake = peer.ctxId;
            }
            peer.state.store(ns, std::memory_order_release);
        }
        if (localWake)
            pipe->scheduleDrain(sd, localWake);

        if (peerWake)
            pipe->scheduleDrain(1 - sd, peerWake);

        // Harvest transferred pipes before `dropped` destructs so their
        // ~TransferredMessagePort sees pipe == nullptr and is a no-op.
        for (auto& message : dropped) {
            for (auto& tp : message.transferredPorts) {
                if (auto p = std::exchange(tp.pipe, nullptr))
                    worklist.append({ WTF::move(p), tp.side });
            }
        }
        // `dropped` (and the RefPtr in the structured binding) destruct
        // outside the lock; they may hold the last ref to pipes whose
        // destructors also take locks.
    }
}

} // namespace WebCore

#endif // BUN_MESSAGEPORT_USES_PIPE
