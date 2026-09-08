#ifndef RDP_CLIPBOARD_STATE_H
#define RDP_CLIPBOARD_STATE_H

#include "extensions/protocol_adapter.h"

struct RdpClipboardFormatRequest {
    uint64_t sequence = 0;
    uint32_t formatId = 0;
    bool files = false;
};

// Called under the adapter clipboard mutex. Wire format responses have no ID,
// so never issue a second request until the previous response has been drained.
class RdpClipboardState {
public:
    uint64_t formatList(bool text, bool files, bool empty) {
        ++snapshot_.sequence;
        queuedFile_ = {};
        snapshot_.kind = files ? "files" : text ? "text" : empty ? "none" : "unsupported";
        snapshot_.text.clear();
        snapshot_.ready = snapshot_.kind != "text";
        return requestLatest();
    }
    uint64_t response(bool valid, std::string text) {
        const uint64_t completed = pending_.sequence;
        const bool wasText = !pending_.files;
        pending_ = {};
        if (completed != 0 && completed == snapshot_.sequence && snapshot_.kind == "text" && wasText) {
            snapshot_.ready = valid;
            if (valid) snapshot_.text = std::move(text);
            return 0;
        }
        return completed != 0 ? requestLatest() : 0;
    }
    void requestFailed(uint64_t sequence) {
        if (pending_.sequence == sequence) pending_ = {};
    }
    void invalidate(bool newCarrier = false) {
        ++snapshot_.sequence;
        snapshot_.kind = "none";
        snapshot_.text.clear();
        snapshot_.ready = false;
        queuedFile_ = {};
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
private:
    uint64_t requestLatest() {
        if (pending_.sequence != 0) return 0;
        if (queuedFile_.sequence == snapshot_.sequence && snapshot_.kind == "files") {
            pending_ = queuedFile_; queuedFile_ = {}; return pending_.sequence;
        }
        if (snapshot_.kind != "text") return 0;
        pending_ = {snapshot_.sequence, 13, false};
        return pending_.sequence;
    }
    ClipboardSnapshot snapshot_;
    RdpClipboardFormatRequest pending_;
    RdpClipboardFormatRequest queuedFile_;
};
#endif
