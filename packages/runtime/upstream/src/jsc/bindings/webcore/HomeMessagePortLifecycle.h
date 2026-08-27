#pragma once

#include <cstdint>

namespace WebCore::MessagePortLifecycle {

// Private flags in MessagePortPipe's reserved low state byte. Keep the linked
// class layouts, public flag values, and queued-count shift unchanged.
inline constexpr uint64_t PeerClosed = 1ull << 3;
inline constexpr uint64_t CloseDispatched = 1ull << 4;

} // namespace WebCore::MessagePortLifecycle

namespace WebCore {
class MessagePort;
class MessagePortPipe;
class MessageEvent;
class ScriptExecutionContext;
struct MessageWithMessagePorts;

namespace WorkerParentPort {
// Native worker transport hooks; neither function changes MessagePort's ABI.
bool send(MessagePortPipe&, uint8_t, MessageWithMessagePorts&&);
void forwardGlobalEvent(MessagePort&, ScriptExecutionContext&, MessageEvent&);
void startForGlobalListener(ScriptExecutionContext&);
}
}
