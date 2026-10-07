#ifndef REMOTEDESK_SHARED_SESSION_CONTEXT_H
#define REMOTEDESK_SHARED_SESSION_CONTEXT_H

#include "video_perf_counters.h"

namespace Render {

// Publishes one exact owner to the existing decoder, renderer, and audio
// sinks as a two-phase transaction. Protocol adapters may keep their own
// transport/input state, but must reuse this process-wide sink boundary.
// `exclusive` (Moonlight, a foreground SSH page) keeps the single-owner rule: admitted only while no other owner is,
// and blocks every other owner while admitted. Picture sessions (RDP, RustDesk, VNC) share the sinks with each other.
bool ActivateSharedSessionSinks(const DecoderSessionIdentity& owner, bool exclusive = false) noexcept;
bool DeactivateSharedSessionSinks(const DecoderSessionIdentity& owner) noexcept;
void DeactivateAllSharedSessionSinks() noexcept;

} // namespace Render

#endif // REMOTEDESK_SHARED_SESSION_CONTEXT_H
