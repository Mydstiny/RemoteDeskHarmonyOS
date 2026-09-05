/**
 * rdp_input_queue.h - lossless priority input queue for the RDP worker
 *
 * Text is an atomic UTF-16 batch.  Keyboard/text events are never evicted;
 * only stale mouse moves are coalesced or discarded under pressure.
 */

#ifndef RDP_INPUT_QUEUE_H
#define RDP_INPUT_QUEUE_H

#include <algorithm>
#include <cstdint>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

enum class RdpInputEventType {
    Key,
    Pause,
    TextBatch,
    Mouse,
    MouseWheel,
};

struct RdpQueuedInputEvent {
    RdpInputEventType type = RdpInputEventType::Key;
    uint16_t flags = 0;
    uint16_t code = 0;
    int x = 0;
    int y = 0;
    bool isMouseMove = false;
    uint64_t geometryEpoch = 0;
    int geometryWidth = 0;
    int geometryHeight = 0;
    std::u16string text;

    static RdpQueuedInputEvent Key(uint16_t flags, uint16_t code) {
        RdpQueuedInputEvent event;
        event.type = RdpInputEventType::Key;
        event.flags = flags;
        event.code = code;
        return event;
    }

    // Pause/Break is an atomic RDP input sequence, not a normal key down/up
    // pair. Keep it on the input worker so it cannot race FreeRDP's connection
    // thread or be confused with NumLock (scan code 0x45).
    static RdpQueuedInputEvent Pause() {
        RdpQueuedInputEvent event;
        event.type = RdpInputEventType::Pause;
        return event;
    }

    static RdpQueuedInputEvent Text(const std::u16string& text) {
        RdpQueuedInputEvent event;
        event.type = RdpInputEventType::TextBatch;
        event.text = text;
        return event;
    }

    static RdpQueuedInputEvent Mouse(uint16_t flags, uint16_t code, int x, int y,
                                     bool isMouseMove, uint64_t geometryEpoch = 0,
                                     int geometryWidth = 0, int geometryHeight = 0) {
        RdpQueuedInputEvent event;
        event.type = RdpInputEventType::Mouse;
        event.flags = flags;
        event.code = code;
        event.x = x;
        event.y = y;
        event.isMouseMove = isMouseMove;
        event.geometryEpoch = geometryEpoch;
        event.geometryWidth = geometryWidth;
        event.geometryHeight = geometryHeight;
        return event;
    }

    static RdpQueuedInputEvent MouseWheel(uint16_t flags, uint16_t code, int x, int y,
                                          uint64_t geometryEpoch = 0,
                                          int geometryWidth = 0, int geometryHeight = 0) {
        RdpQueuedInputEvent event;
        event.type = RdpInputEventType::MouseWheel;
        event.flags = flags;
        event.code = code;
        event.x = x;
        event.y = y;
        event.geometryEpoch = geometryEpoch;
        event.geometryWidth = geometryWidth;
        event.geometryHeight = geometryHeight;
        return event;
    }
};

struct RdpInputGeometrySnapshot {
    uint64_t epoch = 0;
    int width = 0;
    int height = 0;

    bool valid() const {
        return width > 0 && height > 0;
    }
};

struct RdpInputGeometryFenceSnapshot {
    uint64_t requiredEpoch = 0;
    uint64_t acknowledgedEpoch = 0;
    uint64_t droppedPointerEvents = 0;
    bool ready = true;
};

/**
 * Native pointer fence for DesktopResize. ArkUI can observe geometry only on
 * its next poll, so pointer events carry the epoch for which they were mapped.
 * The worker rejects an old event even when resize begins after enqueue.
 */
class RdpInputGeometryFence {
public:
    void reset(uint64_t epoch = 0, int width = 0, int height = 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        requiredEpoch_ = epoch;
        acknowledgedEpoch_ = epoch;
        requiredWidth_ = width;
        requiredHeight_ = height;
        acknowledgedWidth_ = width;
        acknowledgedHeight_ = height;
        droppedPointerEvents_ = 0;
    }

    void beginResize(uint64_t epoch, int width, int height) {
        if (epoch > 0 && width > 0 && height > 0) {
            std::lock_guard<std::mutex> lock(mutex_);
            requiredEpoch_ = epoch;
            requiredWidth_ = width;
            requiredHeight_ = height;
        }
    }

    bool acknowledge(uint64_t epoch, int width, int height) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (epoch != requiredEpoch_ || width != requiredWidth_ || height != requiredHeight_) {
            return false;
        }
        acknowledgedWidth_ = width;
        acknowledgedHeight_ = height;
        acknowledgedEpoch_ = epoch;
        return true;
    }

    RdpInputGeometrySnapshot captureGeometry() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return {acknowledgedEpoch_, acknowledgedWidth_, acknowledgedHeight_};
    }

    bool preparePointer(uint64_t eventEpoch, int sourceWidth, int sourceHeight,
                        bool buttonRelease, int& x, int& y) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (requiredEpoch_ == acknowledgedEpoch_ && eventEpoch == requiredEpoch_) {
            return true;
        }

        // A release must still reach the server so a resize cannot strand a
        // pressed button. FreeRDP serializes coordinates on button-up too, so
        // remap the old geometry into the newest desktop instead of forwarding
        // the stale position unchanged.
        if (buttonRelease && sourceWidth > 0 && sourceHeight > 0 &&
            requiredWidth_ > 0 && requiredHeight_ > 0) {
            x = remapCoordinate(x, sourceWidth, requiredWidth_);
            y = remapCoordinate(y, sourceHeight, requiredHeight_);
            return true;
        }
        ++droppedPointerEvents_;
        return false;
    }

    RdpInputGeometryFenceSnapshot snapshot() const {
        std::lock_guard<std::mutex> lock(mutex_);
        RdpInputGeometryFenceSnapshot snapshot;
        snapshot.requiredEpoch = requiredEpoch_;
        snapshot.acknowledgedEpoch = acknowledgedEpoch_;
        snapshot.droppedPointerEvents = droppedPointerEvents_;
        snapshot.ready = snapshot.requiredEpoch == snapshot.acknowledgedEpoch;
        return snapshot;
    }

private:
    static int remapCoordinate(int value, int sourceExtent, int targetExtent) {
        if (sourceExtent <= 1 || targetExtent <= 1) {
            return 0;
        }
        const int clamped = std::clamp(value, 0, sourceExtent - 1);
        const int64_t numerator = static_cast<int64_t>(clamped) * (targetExtent - 1) +
            (sourceExtent - 1) / 2;
        return static_cast<int>(numerator / (sourceExtent - 1));
    }

    mutable std::mutex mutex_;
    uint64_t requiredEpoch_ = 0;
    uint64_t acknowledgedEpoch_ = 0;
    uint64_t droppedPointerEvents_ = 0;
    int requiredWidth_ = 0;
    int requiredHeight_ = 0;
    int acknowledgedWidth_ = 0;
    int acknowledgedHeight_ = 0;
};

/**
 * Pointer events retain their geometry metadata until the event-loop thread
 * performs the actual FreeRDP send. A notification in FreeRDP's message queue
 * preserves ordering with keyboard events; this queue preserves the payload.
 */
class RdpFinalPointerQueue {
public:
    void push(const RdpQueuedInputEvent& event) {
        events_.push_back(event);
    }

    bool pop(RdpQueuedInputEvent& event) {
        if (events_.empty()) {
            return false;
        }
        event = std::move(events_.front());
        events_.pop_front();
        return true;
    }

    bool discardNewest() {
        if (events_.empty()) {
            return false;
        }
        events_.pop_back();
        return true;
    }

    void clear() {
        events_.clear();
    }

    size_t depth() const {
        return events_.size();
    }

private:
    std::deque<RdpQueuedInputEvent> events_;
};

enum class RdpInputEnqueueResult {
    Enqueued,
    ReplacedMouseMove,
    DroppedMouseMove,
};

struct RdpUnicodeDispatch {
    uint16_t flags = 0;
    uint16_t code = 0;
};

template <typename Dispatch>
void DispatchTextBatch(const std::u16string& text, uint16_t releaseFlag, Dispatch&& dispatch) {
    for (char16_t unit : text) {
        const uint16_t code = static_cast<uint16_t>(unit);
        dispatch(0, code);
        dispatch(releaseFlag, code);
    }
}

class RdpInputQueue {
public:
    static constexpr size_t kSoftMaxEvents = 256U;

    RdpInputEnqueueResult enqueue(RdpQueuedInputEvent event) {
        if (event.isMouseMove) {
            return enqueueMouseMove(std::move(event));
        }

        // Every non-move event is an ordering barrier. Materialize the latest
        // pointer target before it so clicks, drags, wheels, text and keys
        // retain their protocol order without retaining a full move backlog.
        flushPendingMouseMove();
        if (depth() >= kSoftMaxEvents) {
            ++nonDisposableOverflow_;
        }
        textUnitDepth_ += event.text.size();
        reliableEvents_.push_back(std::move(event));
        updateMaxDepth();
        return RdpInputEnqueueResult::Enqueued;
    }

    bool pop(RdpQueuedInputEvent& event) {
        if (!reliableEvents_.empty()) {
            event = std::move(reliableEvents_.front());
            reliableEvents_.pop_front();
            textUnitDepth_ -= event.text.size();
            return true;
        }
        if (!pendingMouseMove_.has_value()) {
            return false;
        }
        event = std::move(*pendingMouseMove_);
        pendingMouseMove_.reset();
        return true;
    }

    void clear() {
        reliableEvents_.clear();
        pendingMouseMove_.reset();
        textUnitDepth_ = 0;
    }

    void resetMetrics() {
        maxDepth_ = depth();
        droppedMouseMoves_ = 0;
        droppedNonDisposable_ = 0;
        nonDisposableOverflow_ = 0;
    }

    size_t depth() const { return reliableEvents_.size() + (pendingMouseMove_.has_value() ? 1U : 0U); }
    size_t maxDepth() const { return maxDepth_; }
    size_t textUnitDepth() const { return textUnitDepth_; }
    size_t droppedMouseMoves() const { return droppedMouseMoves_; }
    size_t droppedNonDisposable() const { return droppedNonDisposable_; }
    size_t nonDisposableOverflow() const { return nonDisposableOverflow_; }

private:
    RdpInputEnqueueResult enqueueMouseMove(RdpQueuedInputEvent event) {
        if (pendingMouseMove_.has_value()) {
            *pendingMouseMove_ = std::move(event);
            ++droppedMouseMoves_;
            return RdpInputEnqueueResult::ReplacedMouseMove;
        }
        pendingMouseMove_ = std::move(event);
        updateMaxDepth();
        return RdpInputEnqueueResult::Enqueued;
    }

    void flushPendingMouseMove() {
        if (!pendingMouseMove_.has_value()) {
            return;
        }
        reliableEvents_.push_back(std::move(*pendingMouseMove_));
        pendingMouseMove_.reset();
    }

    void updateMaxDepth() {
        if (depth() > maxDepth_) {
            maxDepth_ = depth();
        }
    }

    std::deque<RdpQueuedInputEvent> reliableEvents_;
    std::optional<RdpQueuedInputEvent> pendingMouseMove_;
    size_t textUnitDepth_ = 0;
    size_t maxDepth_ = 0;
    size_t droppedMouseMoves_ = 0;
    size_t droppedNonDisposable_ = 0;
    size_t nonDisposableOverflow_ = 0;
};

#endif // RDP_INPUT_QUEUE_H
