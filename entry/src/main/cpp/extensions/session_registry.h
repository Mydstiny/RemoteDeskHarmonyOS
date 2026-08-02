#ifndef REMOTEDESK_SESSION_REGISTRY_H
#define REMOTEDESK_SESSION_REGISTRY_H

#include <map>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

// Thread-safe ownership registry. Lookups are value snapshots: the returned
// shared_ptr keeps the context alive while callers run adapter/NAPI/callback
// code, and no registry mutex is held across that external work.
template <typename Session>
class SessionRegistry final {
public:
    using SessionPtr = std::shared_ptr<Session>;

    struct SnapshotEntry {
        int first = 0;
        SessionPtr second;
    };

    class Lookup final {
    public:
        Lookup() = default;
        Lookup(int sessionId, SessionPtr session)
            : entry_ {sessionId, std::move(session)} {}

        const SnapshotEntry* operator->() const { return &entry_; }
        bool operator==(const Lookup& other) const {
            return entry_.second == other.entry_.second;
        }
        bool operator!=(const Lookup& other) const {
            return entry_.second != other.entry_.second;
        }

    private:
        SnapshotEntry entry_;
    };

    Lookup find(int sessionId) const {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = sessions_.find(sessionId);
        if (it == sessions_.end()) {
            return {};
        }
        return Lookup(sessionId, it->second);
    }

    Lookup end() const { return {}; }

    void insertOrAssign(int sessionId, SessionPtr session) {
        std::lock_guard<std::mutex> lock(mutex_);
        sessions_[sessionId] = std::move(session);
    }

    SessionPtr erase(int sessionId) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = sessions_.find(sessionId);
        if (it == sessions_.end()) {
            return nullptr;
        }
        SessionPtr session = std::move(it->second);
        sessions_.erase(it);
        return session;
    }

    bool eraseIf(int sessionId, const SessionPtr& expected) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = sessions_.find(sessionId);
        if (it == sessions_.end() || (expected && it->second != expected)) {
            return false;
        }
        sessions_.erase(it);
        return true;
    }

    std::vector<std::pair<int, SessionPtr>> snapshot() const {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<std::pair<int, SessionPtr>> result;
        result.reserve(sessions_.size());
        for (const auto& entry : sessions_) {
            if (entry.second) {
                result.push_back(entry);
            }
        }
        return result;
    }

    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        sessions_.clear();
    }

private:
    mutable std::mutex mutex_;
    std::map<int, SessionPtr> sessions_;
};

#endif // REMOTEDESK_SESSION_REGISTRY_H
