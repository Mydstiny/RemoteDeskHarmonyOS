#include "common/network_generation_fence.h"

namespace remotedesk::net {

NetworkGenerationFence::NetworkGenerationFence(
    uint64_t initialGeneration, bool initiallyAvailable)
    : current_ {initialGeneration, initiallyAvailable} {}

bool NetworkGenerationFence::update(bool available, uint64_t generation) {
    if (generation == 0) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation <= current_.generation) {
        return false;
    }
    current_ = {generation, available};
    return true;
}

NetworkGenerationSnapshot NetworkGenerationFence::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return current_;
}

bool NetworkGenerationFence::shouldCancel(
    const NetworkGenerationSnapshot& captured) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return !current_.available || captured.generation == 0 ||
        captured.generation != current_.generation;
}

NetworkGenerationFence& ProcessNetworkGenerationFence() {
    static NetworkGenerationFence fence;
    return fence;
}

} // namespace remotedesk::net
