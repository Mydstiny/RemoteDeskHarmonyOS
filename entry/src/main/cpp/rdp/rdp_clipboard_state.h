#ifndef RDP_CLIPBOARD_STATE_H
#define RDP_CLIPBOARD_STATE_H

#include "extensions/protocol_adapter.h"
#include <deque>

struct RdpClipboardFormatRequest {
    uint64_t sequence = 0;
    uint32_t formatId = 0;
    bool files = false;
    uint64_t richRequestId = 0;
};

// Called under the adapter clipboard mutex. Wire format responses have no ID,
// so never issue a second request until the previous response has been drained.
class RdpClipboardState {
public:
    uint64_t formatList(bool text, bool files, bool empty, bool rich = false) {
        ++snapshot_.sequence;
        queuedFile_ = {}; queuedRich_.clear();
        snapshot_.kind = files ? "files" : rich ? "rich" : text ? "text" : empty ? "none" : "unsupported";
        snapshot_.text.clear();
        snapshot_.ready = snapshot_.kind != "text";
        return requestLatest();
    }
    uint64_t response(bool valid, std::string text) {
        const uint64_t completed = pending_.sequence;
        const bool wasText = !pending_.files && !pending_.richRequestId;
        pending_ = {};
        if (completed != 0 && completed == snapshot_.sequence && snapshot_.kind == "text" && wasText) {
            snapshot_.ready = valid;
            if (valid) snapshot_.text = std::move(text);
            if (queuedRich_.empty()) return 0;
        }
        return completed != 0 ? requestLatest() : 0;
    }
    void requestFailed(uint64_t sequence) {
        // A failed send can have partially reached the transport. Keep the
        // untagged-response barrier until reply or carrier replacement.
        (void)sequence;
    }
    void invalidate(bool newCarrier = false) {
        ++snapshot_.sequence;
        snapshot_.kind = "none";
        snapshot_.text.clear();
        snapshot_.ready = false;
        queuedFile_ = {}; queuedRich_.clear();
        if (newCarrier) pending_ = {};
    }
    void cancelQueuedFileRequest(uint64_t sequence) {
        if (queuedFile_.sequence == sequence) queuedFile_ = {};
    }
    const ClipboardSnapshot& snapshot() const { return snapshot_; }
    RdpClipboardFormatRequest pendingRequest() const { return pending_; }
    bool requestFiles(uint64_t sequence, uint32_t formatId) {
        if (!sequence || !formatId || snapshot_.sequence != sequence || snapshot_.kind != "files") return false;
        if (pending_.sequence == sequence && pending_.files) return true;
        queuedFile_ = {sequence, formatId, true};
        (void)requestLatest();
        return true;
    }
    bool requestRich(uint64_t sequence, uint32_t formatId, uint64_t requestId) {
        if (!sequence || sequence != snapshot_.sequence || !formatId || !requestId) return false;
        // A replaced request of this format must still drain if already sent.
        for (auto it=queuedRich_.begin();it!=queuedRich_.end();) {
            if (it->formatId==formatId) it=queuedRich_.erase(it); else ++it;
        }
        if (queuedRich_.size() >= 5) return false;
        queuedRich_.push_back({sequence, formatId, false, requestId});
        (void)requestLatest(); return true;
    }
    void cancelQueuedRichRequest(uint64_t requestId) {
        for (auto it=queuedRich_.begin();it!=queuedRich_.end();) {
            if (it->richRequestId==requestId) it=queuedRich_.erase(it); else ++it;
        }
    }
private:
    uint64_t requestLatest() {
        if (pending_.sequence != 0) return 0;
        if (queuedFile_.sequence == snapshot_.sequence && snapshot_.kind == "files") {
            pending_ = queuedFile_; queuedFile_ = {}; return pending_.sequence;
        }
        while (!queuedRich_.empty()) {
            auto next=queuedRich_.front(); queuedRich_.pop_front();
            if (next.sequence==snapshot_.sequence) { pending_=next; return pending_.sequence; }
        }
        if (snapshot_.kind != "text" || snapshot_.ready) return 0;
        pending_ = {snapshot_.sequence, 13, false};
        return pending_.sequence;
    }
    ClipboardSnapshot snapshot_;
    RdpClipboardFormatRequest pending_;
    RdpClipboardFormatRequest queuedFile_;
    std::deque<RdpClipboardFormatRequest> queuedRich_;
};
#endif
