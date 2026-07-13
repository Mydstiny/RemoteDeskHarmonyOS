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
#include <string>
#include <utility>

enum class RdpInputEventType {
    Key,
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

        purgeMouseMoves();
        if (events_.size() >= kSoftMaxEvents) {
            ++nonDisposableOverflow_;
        }
        textUnitDepth_ += event.text.size();
        events_.push_back(std::move(event));
        updateMaxDepth();
        return RdpInputEnqueueResult::Enqueued;
    }

    bool pop(RdpQueuedInputEvent& event) {
        if (events_.empty()) {
            return false;
        }
        event = std::move(events_.front());
        events_.pop_front();
        textUnitDepth_ -= event.text.size();
        return true;
    }

    void clear() {
        events_.clear();
        textUnitDepth_ = 0;
    }

    void resetMetrics() {
        maxDepth_ = events_.size();
        droppedMouseMoves_ = 0;
        droppedNonDisposable_ = 0;
        nonDisposableOverflow_ = 0;
    }

    size_t depth() const { return events_.size(); }
    size_t maxDepth() const { return maxDepth_; }
    size_t textUnitDepth() const { return textUnitDepth_; }
    size_t droppedMouseMoves() const { return droppedMouseMoves_; }
    size_t droppedNonDisposable() const { return droppedNonDisposable_; }
    size_t nonDisposableOverflow() const { return nonDisposableOverflow_; }

private:
    RdpInputEnqueueResult enqueueMouseMove(RdpQueuedInputEvent event) {
        if (!events_.empty() && events_.back().isMouseMove) {
            events_.back() = std::move(event);
            ++droppedMouseMoves_;
            return RdpInputEnqueueResult::ReplacedMouseMove;
        }
        if (events_.size() >= kSoftMaxEvents) {
            ++droppedMouseMoves_;
            return RdpInputEnqueueResult::DroppedMouseMove;
        }
        events_.push_back(std::move(event));
        updateMaxDepth();
        return RdpInputEnqueueResult::Enqueued;
    }

    void purgeMouseMoves() {
        for (auto it = events_.begin(); it != events_.end();) {
            if (it->isMouseMove) {
                it = events_.erase(it);
                ++droppedMouseMoves_;
            } else {
                ++it;
            }
        }
    }

    void updateMaxDepth() {
        if (events_.size() > maxDepth_) {
            maxDepth_ = events_.size();
        }
    }

    std::deque<RdpQueuedInputEvent> events_;
    size_t textUnitDepth_ = 0;
    size_t maxDepth_ = 0;
    size_t droppedMouseMoves_ = 0;
    size_t droppedNonDisposable_ = 0;
    size_t nonDisposableOverflow_ = 0;
};

#endif // RDP_INPUT_QUEUE_H
