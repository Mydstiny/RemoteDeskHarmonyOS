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

bool NetworkGenerationFence::admitIfCurrent(
    const NetworkGenerationSnapshot& captured,
    const std::function<void()>& admission) const {
    if (!admission) { return false; }
    NetworkGenerationAdmission lease = acquireAdmission(captured);
    if (!lease) { return false; }
    admission();
    return true;
}

NetworkGenerationAdmission NetworkGenerationFence::acquireAdmission(
    const NetworkGenerationSnapshot& captured) const {
    std::unique_lock<std::mutex> lock(mutex_);
    const bool current = captured.available && current_.available &&
        captured.generation != 0 &&
        captured.generation == current_.generation;
    if (!current) { lock.unlock(); }
    return NetworkGenerationAdmission(std::move(lock), current);
}

NetworkGenerationFence& ProcessNetworkGenerationFence() {
    static NetworkGenerationFence fence;
    return fence;
}

} // namespace remotedesk::net
