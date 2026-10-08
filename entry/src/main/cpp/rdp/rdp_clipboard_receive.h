#ifndef RDP_CLIPBOARD_RECEIVE_H
#define RDP_CLIPBOARD_RECEIVE_H
#include "rdp_transfer_types.h"
#include "extensions/session_teardown_executor.h"
#include <cstddef>
#include <functional>
#include <memory>

struct RdpClipboardFileRequest {
    uint32_t streamId = 0;
    uint32_t index = 0;
    uint64_t offset = 0;
    uint32_t requested = 0;
    bool sizeQuery = false;
    uint32_t clipDataId = 0;
};
struct RdpClipboardReceiveOptions {
    /** A stalled transfer stops when one request goes this long without an answer. */
    uint32_t requestTimeoutMs = 15000;
    /** A steady transfer is not cut off: 24 hours bounds only a runaway one (it used to be 30 minutes). */
    uint32_t overallTimeoutMs = 86400000;
    uint64_t maxTotalBytes = 2ULL * 1024 * 1024 * 1024;
};
class RdpClipboardReceive {
public:
    using Sender = std::function<bool(const RdpClipboardFileRequest&)>;
    using Unlocker = std::function<void(uint32_t)>;
    explicit RdpClipboardReceive(RdpClipboardReceiveOptions options = {});
    ~RdpClipboardReceive();
    RdpClipboardReceive(const RdpClipboardReceive&) = delete;
    RdpClipboardReceive& operator=(const RdpClipboardReceive&) = delete;
    bool start(uint64_t taskId, const RemoteClipboardFileOffer& offer,
        const std::vector<uint32_t>& selected, int stageDirectoryFd,
        uint32_t clipDataId, Sender sender, Unlocker unlocker);
    bool response(uint32_t streamId, bool success, const uint8_t* data, size_t size);
    bool cancel(const std::string& reason = "cancelled");
    void offerChanged(uint64_t sequence);
    RemoteClipboardReceiveStatus status() const;
    struct State;
private:
    std::shared_ptr<State> state_;
    SessionTeardown::Executor worker_;
};
#endif
