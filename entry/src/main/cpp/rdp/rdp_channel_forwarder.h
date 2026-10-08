#ifndef RDP_CHANNEL_FORWARDER_H
#define RDP_CHANNEL_FORWARDER_H
#include "rdp_channel_observer.h"

// Owner/carrier admission is performed by the adapter before reaching here.
// Observation is optional; neither parser failures nor allocation failures may
// consume a transport packet or change the original callback result.
namespace RdpChannelForwarder {
template<typename Original>
auto receive(RdpChannelObserver* observer, const uint8_t* bytes, size_t size,
    uint32_t flags, size_t totalSize, Original original) -> decltype(original()) {
    if (observer) {
        try { observer->receive(bytes, size, flags, totalSize); }
        catch (...) { observer->markUncertain(); }
    }
    return original();
}
template<typename Original>
auto send(RdpChannelObserver* observer, const uint8_t* bytes, size_t size, Original original) -> decltype(original()) {
    const auto result = original();
    if (result && observer) {
        try { observer->sent(bytes, size); }
        catch (...) { observer->markUncertain(); }
    }
    return result;
}
}
#endif
