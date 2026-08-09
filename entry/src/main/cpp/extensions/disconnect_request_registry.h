#ifndef REMOTEDESK_DISCONNECT_REQUEST_REGISTRY_H
#define REMOTEDESK_DISCONNECT_REQUEST_REGISTRY_H

#include <cstddef>
#include <cstdint>
#include <map>
#include <mutex>
#include <utility>
#include <vector>

// Ordinary-mutex registry for teardown request snapshots. Callers receive
// values while holding no registry lock; adapter/NAPI/teardown work must stay
// outside this class so a completion callback can re-enter the registry.
class DisconnectRequestRegistry final {
public:
    std::uint64_t find(int sessionId) const {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = requests_.find(sessionId);
        return it == requests_.end() ? 0 : it->second;
    }

    void insertOrAssign(int sessionId, std::uint64_t requestId) {
        std::lock_guard<std::mutex> lock(mutex_);
        requests_[sessionId] = requestId;
    }

    bool eraseIf(int sessionId, std::uint64_t requestId) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = requests_.find(sessionId);
        if (it == requests_.end() || it->second != requestId) {
            return false;
        }
        requests_.erase(it);
        return true;
    }

    std::vector<std::pair<int, std::uint64_t>> snapshot() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return {requests_.begin(), requests_.end()};
    }

    std::size_t size() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return requests_.size();
    }

    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        requests_.clear();
    }

private:
    mutable std::mutex mutex_;
    std::map<int, std::uint64_t> requests_;
};

#endif // REMOTEDESK_DISCONNECT_REQUEST_REGISTRY_H
