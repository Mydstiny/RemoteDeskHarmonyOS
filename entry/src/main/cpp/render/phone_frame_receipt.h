#ifndef REMOTEDESK_PHONE_FRAME_RECEIPT_H
#define REMOTEDESK_PHONE_FRAME_RECEIPT_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <mutex>

namespace Render {

struct PhoneFrameIdentity {
    uint64_t sessionId = 0;
    uint64_t generation = 0;
    uint64_t ownerToken = 0;
    uint64_t streamEpoch = 0;
    uint32_t geometryEpoch = 0;
    int display = -1;
    int width = 0;
    int height = 0;
};

struct PhoneFrameReceipt {
    PhoneFrameIdentity identity;
    uint64_t originalTimestamp = 0;
    std::function<void(const PhoneFrameIdentity&, int, int)> didPresent;
};
using PhoneFrameReceiptPtr = std::shared_ptr<const PhoneFrameReceipt>;

struct PhoneFrameTrackerState {
    struct Entry { PhoneFrameReceiptPtr receipt; bool decoded = false; };
    std::mutex mutex;
    uint64_t generation = 1;
    std::map<int64_t, Entry> pending;
};

// A ticket belongs to an actual decoder output, not the latest ingress frame.
// Decoder callback gates own the in-flight presentation lifetime. Do not hold
// the tracker lock across the bridge callback (ingress takes these in reverse).
class PhoneDecodedFrame {
public:
    PhoneDecodedFrame(std::shared_ptr<PhoneFrameTrackerState> state, uint64_t generation,
                      PhoneFrameReceiptPtr receipt, int64_t token)
        : state_(std::move(state)), generation_(generation), receipt_(std::move(receipt)), token_(token) {}

    bool presented(int width, int height) const {
        {
            std::lock_guard<std::mutex> lock(state_->mutex);
            if (generation_ != state_->generation || !receipt_ || !receipt_->didPresent ||
                receipt_->identity.geometryEpoch == 0 || width <= 0 || height <= 0) return false;
        }
        receipt_->didPresent(receipt_->identity, width, height);
        return true;
    }
    int64_t token() const { return token_; }

private:
    std::shared_ptr<PhoneFrameTrackerState> state_;
    uint64_t generation_;
    PhoneFrameReceiptPtr receipt_;
    int64_t token_;
};
using PhoneDecodedFramePtr = std::shared_ptr<const PhoneDecodedFrame>;

// Constructed lazily for explicit phone input only. Existing media PTS and
// scheduling are untouched for every frame without a phone receipt.
class PhoneFrameTracker {
public:
    static constexpr size_t kCapacity = 256;
    PhoneFrameTracker() = default;
    ~PhoneFrameTracker() { clear(); }
    PhoneFrameTracker(const PhoneFrameTracker&) = delete;
    PhoneFrameTracker& operator=(const PhoneFrameTracker&) = delete;

    int64_t submit(const PhoneFrameReceiptPtr& receipt) {
        if (!receipt) return 0;
        static std::atomic<int64_t> nextToken {1};
        int64_t token = nextToken.load(std::memory_order_relaxed);
        do {
            if (token <= 0 || token == std::numeric_limits<int64_t>::max()) return 0;
        } while (!nextToken.compare_exchange_weak(token, token + 1, std::memory_order_relaxed));
        std::lock_guard<std::mutex> lock(state_->mutex);
        // Drop only evidence for old buffered frames. Never guess another
        // frame's identity, and never change the decoder's queue/drop policy.
        if (state_->pending.size() >= kCapacity) state_->pending.erase(state_->pending.begin());
        state_->pending.emplace(token, PhoneFrameTrackerState::Entry {receipt, false});
        return token;
    }

    void decoded(int64_t outputPts) {
        std::lock_guard<std::mutex> lock(state_->mutex);
        const auto found = state_->pending.find(outputPts);
        if (found != state_->pending.end()) found->second.decoded = true;
    }

    PhoneDecodedFramePtr takeDecoded(int64_t actualTextureTimestamp) {
        std::lock_guard<std::mutex> lock(state_->mutex);
        const auto found = state_->pending.find(actualTextureTimestamp);
        if (found == state_->pending.end() || !found->second.decoded) return {};
        auto ticket = std::make_shared<PhoneDecodedFrame>(
            state_, state_->generation, found->second.receipt, actualTextureTimestamp);
        state_->pending.erase(found);
        return ticket;
    }

    void discard(int64_t token) {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->pending.erase(token);
    }

    void clear() {
        std::lock_guard<std::mutex> lock(state_->mutex);
        ++state_->generation;
        state_->pending.clear();
    }

    size_t pendingCount() const {
        std::lock_guard<std::mutex> lock(state_->mutex);
        return state_->pending.size();
    }

private:
    std::shared_ptr<PhoneFrameTrackerState> state_ = std::make_shared<PhoneFrameTrackerState>();
};

inline std::shared_ptr<PhoneFrameTracker> EnsurePhoneFrameTracker(
    std::shared_ptr<PhoneFrameTracker>& slot) {
    auto tracker = std::atomic_load(&slot);
    if (!tracker) {
        auto created = std::make_shared<PhoneFrameTracker>();
        if (std::atomic_compare_exchange_strong(&slot, &tracker, created)) tracker = created;
    }
    return tracker;
}

inline void ClearPhoneFrameTracker(std::shared_ptr<PhoneFrameTracker>& slot) {
    const auto tracker = std::atomic_exchange(&slot, std::shared_ptr<PhoneFrameTracker>());
    if (tracker) tracker->clear();
}

} // namespace Render
#endif
