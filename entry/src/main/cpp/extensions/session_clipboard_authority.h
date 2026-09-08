#ifndef REMOTEDESK_SESSION_CLIPBOARD_AUTHORITY_H
#define REMOTEDESK_SESSION_CLIPBOARD_AUTHORITY_H

#include <cstdint>
#include <mutex>

// One authority per native process, independent of ArkTS runtime and renderer
// ownership. Validators must check the actual registry generation/lifecycle;
// they run while this mutex is held. A synchronous commit may reenter owns(),
// but cannot claim/revoke authority from inside the same commit.
class SessionClipboardAuthority final {
public:
    static constexpr uint64_t kMaxSafeInteger = 9007199254740991ULL;

    // A nonzero seed is useful for checking exhaustion without token wraparound.
    explicit SessionClipboardAuthority(uint64_t initialEpoch = 0)
        : epoch_(initialEpoch) {}

    template <typename IsAlive>
    uint64_t claim(int32_t sessionId, uint64_t generation, bool replaceExisting,
                   const IsAlive& isAlive) {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        if (commitDepth_ != 0) return 0;
        discardDeadOwner(isAlive);
        if (!validIdentity(sessionId, generation) ||
            !alive(isAlive, sessionId, generation) ||
            (token_ != 0 && !replaceExisting) || epoch_ >= kMaxSafeInteger) {
            return 0;
        }
        sessionId_ = sessionId;
        generation_ = generation;
        token_ = ++epoch_;
        return token_;
    }

    template <typename IsAlive>
    bool owns(int32_t sessionId, uint64_t generation, uint64_t token,
              const IsAlive& isAlive) {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        discardDeadOwner(isAlive);
        return matches(sessionId, generation, token);
    }

    template <typename IsAlive>
    bool revoke(int32_t sessionId, uint64_t generation, uint64_t token,
                const IsAlive& isAlive) {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        if (commitDepth_ != 0) return false;
        discardDeadOwner(isAlive);
        if (!matches(sessionId, generation, token)) {
            return false;
        }
        clearOwner();
        return true;
    }

    // Run only the final synchronous publication/write. Never retain callbacks or
    // wait for an asynchronous task while holding authority. A competing runtime's
    // handoff linearizes before this method or after the synchronous operation.
    template <typename IsAlive, typename Commit>
    bool withAuthority(int32_t sessionId, uint64_t generation, uint64_t token,
                       const IsAlive& isAlive, const Commit& commit) {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        discardDeadOwner(isAlive);
        if (!matches(sessionId, generation, token)) return false;
        bool accepted = false;
        ++commitDepth_;
        try { accepted = commit(); } catch (...) { accepted = false; }
        --commitDepth_;
        discardDeadOwner(isAlive);
        return accepted && matches(sessionId, generation, token);
    }

private:
    static bool validIdentity(int32_t sessionId, uint64_t generation) {
        return sessionId > 0 && generation > 0 && generation <= kMaxSafeInteger;
    }

    template <typename IsAlive>
    static bool alive(const IsAlive& isAlive, int32_t sessionId, uint64_t generation) {
        try {
            return isAlive(sessionId, generation);
        } catch (...) {
            return false;
        }
    }

    template <typename IsAlive>
    void discardDeadOwner(const IsAlive& isAlive) {
        if (token_ != 0 && !alive(isAlive, sessionId_, generation_)) {
            clearOwner();
        }
    }

    bool matches(int32_t sessionId, uint64_t generation, uint64_t token) const {
        return validIdentity(sessionId, generation) && token > 0 &&
            token <= kMaxSafeInteger && token_ == token &&
            sessionId_ == sessionId && generation_ == generation;
    }

    void clearOwner() {
        sessionId_ = 0;
        generation_ = 0;
        token_ = 0;
    }

    std::recursive_mutex mutex_;
    uint32_t commitDepth_ = 0;
    uint64_t epoch_ = 0;
    int32_t sessionId_ = 0;
    uint64_t generation_ = 0;
    uint64_t token_ = 0;
};

#endif // REMOTEDESK_SESSION_CLIPBOARD_AUTHORITY_H
