#ifndef RDP_CHANNEL_OBSERVER_H
#define RDP_CHANNEL_OBSERVER_H
#include "rdp_transfer_types.h"
#include <cstddef>
#include <map>
#include <mutex>

// Observes authenticated static-channel bytes; never owns or alters transport
// buffers, never suppresses forwarding, and retains only bounded metadata.
class RdpChannelObserver {
public:
    void reset(uint64_t generation);
    void registered(uint32_t deviceId);
    void unavailable(const std::string& reason);
    void markUncertain() noexcept;
    void receive(const uint8_t* bytes, size_t size, uint32_t flags, size_t totalSize);
    void sent(const uint8_t* bytes, size_t size);
    RdpDriveStatus status() const;
    std::vector<RdpReceivedFileFact> files() const;
private:
    struct Device { bool announced = false; bool replied = false; uint32_t status = 0; bool removed = false; };
    struct Request { uint32_t fileId = 0; uint32_t major = 0; uint32_t bytes = 0; std::string path; std::string rename; };
    void packet(const uint8_t*, size_t, size_t, bool);
    void incomplete();
    void updatePhase();
    void completion(const uint8_t*, size_t);
    mutable std::mutex mutex_;
    RdpDriveStatus status_;
    std::map<uint32_t, Device> devices_;
    std::map<uint32_t, Request> requests_;
    std::map<uint32_t, std::string> handles_;
    std::map<std::string, RdpReceivedFileFact> facts_;
    std::vector<uint8_t> prefix_;
    size_t received_ = 0;
    size_t expected_ = 0;
    bool fragmenting_ = false;
    uint64_t change_ = 0;
    bool unavailable_ = false;
};
#endif
