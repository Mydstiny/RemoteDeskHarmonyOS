#ifndef SSH_PENDING_CONNECT_REGISTRY_H
#define SSH_PENDING_CONNECT_REGISTRY_H

#include <cstdint>
#include <map>
#include <mutex>
#include <vector>

/**
 * Tracks SSH handshakes before their async Promise settles.
 *
 * The generation check is intentional: a late completion from an older
 * identity must not remove a newer entry if a caller reuses a session id in a
 * test harness or during process recovery.
 */
struct SshPendingConnectIdentity final {
    int sessionId = -1;
    uint64_t generation = 0;

    bool valid() const noexcept { return sessionId > 0 && generation > 0; }
};

class SshPendingConnectRegistry final {
public:
    bool add(const SshPendingConnectIdentity& identity) {
        if (!identity.valid()) {
            return false;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        return entries_.emplace(identity.sessionId, identity.generation).second;
    }

    bool remove(const SshPendingConnectIdentity& identity) {
        if (!identity.valid()) {
            return false;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = entries_.find(identity.sessionId);
        if (it == entries_.end() || it->second != identity.generation) {
            return false;
        }
        entries_.erase(it);
        return true;
    }

    bool contains(const SshPendingConnectIdentity& identity) const {
        if (!identity.valid()) {
            return false;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = entries_.find(identity.sessionId);
        return it != entries_.end() && it->second == identity.generation;
    }

    std::vector<SshPendingConnectIdentity> snapshot() const {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<SshPendingConnectIdentity> result;
        result.reserve(entries_.size());
        for (const auto& entry : entries_) {
            result.push_back(SshPendingConnectIdentity {entry.first, entry.second});
        }
        return result;
    }

    int firstSessionId() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return entries_.empty() ? -1 : entries_.begin()->first;
    }

    size_t size() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return entries_.size();
    }

private:
    mutable std::mutex mutex_;
    std::map<int, uint64_t> entries_;
};

#endif // SSH_PENDING_CONNECT_REGISTRY_H
