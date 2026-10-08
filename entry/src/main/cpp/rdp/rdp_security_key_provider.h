#pragma once

#include <cstdint>

// Adapter-facing lifecycle of the RDP security-key broker (Debug builds with the RDPEWA channel only).
namespace RdpSecurityKey {

// Creates the broker and its cancellation event for an RDP context before channels load.
bool AttachContext(void* context, uint64_t sessionId);
// Fails every current and future wait, so the channel worker can be joined during disconnect.
void CloseContext(void* context);
// Removes the broker after channel teardown, before the context is freed.
void DetachContext(void* context);

} // namespace RdpSecurityKey
