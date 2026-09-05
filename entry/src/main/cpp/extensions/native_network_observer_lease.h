#pragma once

namespace remotedesk::net {

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_NETWORK_OBSERVER_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_NETWORK_OBSERVER_HIDDEN
#endif

/**
 * Keeps the process-wide default-network observer registered for a native
 * consumer that is not represented by ExtensionLoader's SessionContext.
 * Every successful acquire must be paired with one release.
 */
REMOTEDESK_NETWORK_OBSERVER_HIDDEN
bool AcquireProcessNetworkObserverLease() noexcept;

REMOTEDESK_NETWORK_OBSERVER_HIDDEN
void ReleaseProcessNetworkObserverLease() noexcept;

#undef REMOTEDESK_NETWORK_OBSERVER_HIDDEN

} // namespace remotedesk::net
