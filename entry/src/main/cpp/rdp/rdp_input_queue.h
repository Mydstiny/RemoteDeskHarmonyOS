/**
 * rdp_input_queue.h - lossless priority input queue for the RDP worker
 *
 * Text is an atomic UTF-16 batch.  Keyboard/text events are never evicted;
 * only stale mouse moves are coalesced or discarded under pressure.
 */

#ifndef RDP_INPUT_QUEUE_H
#define RDP_INPUT_QUEUE_H

#include <cstdint>
#include <deque>
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
                                     bool isMouseMove) {
        RdpQueuedInputEvent event;
        event.type = RdpInputEventType::Mouse;
        event.flags = flags;
        event.code = code;
        event.x = x;
        event.y = y;
        event.isMouseMove = isMouseMove;
        return event;
    }

    static RdpQueuedInputEvent MouseWheel(uint16_t flags, uint16_t code, int x, int y) {
        RdpQueuedInputEvent event;
        event.type = RdpInputEventType::MouseWheel;
        event.flags = flags;
        event.code = code;
        event.x = x;
        event.y = y;
        return event;
    }
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
