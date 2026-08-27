#pragma once

#include <cstdint>

namespace WebCore::MessagePortLifecycle {

// Private flags in MessagePortPipe's reserved low state byte. Keep the linked
// class layouts, public flag values, and queued-count shift unchanged.
inline constexpr uint64_t PeerClosed = 1ull << 3;
inline constexpr uint64_t CloseDispatched = 1ull << 4;

} // namespace WebCore::MessagePortLifecycle
