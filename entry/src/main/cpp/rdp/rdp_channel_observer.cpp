#include "rdp_channel_observer.h"
#include "rdp_clipboard_codec.h"
#include <algorithm>
#include <limits>

namespace {
constexpr size_t kPrefixBudget = 65536;
constexpr size_t kFactBudget = 1024;
constexpr size_t kRequestBudget = 1024;
constexpr uint16_t kCore = 0x4472, kAnnounce = 0x4441, kReply = 0x6472,
    kRequest = 0x4952, kCompletion = 0x4943, kRemove = 0x444D;
constexpr uint32_t kCreate = 0, kClose = 2, kWrite = 4, kSetInformation = 6;
uint16_t u16(const uint8_t* p) { return uint16_t(p[0]) | (uint16_t(p[1]) << 8); }
uint32_t u32(const uint8_t* p) { return uint32_t(u16(p)) | (uint32_t(u16(p + 2)) << 16); }
bool observedPath(const uint8_t* data, size_t size, std::string& path) {
    if (size == 0) { path.clear(); return true; }
    if (size > 32768 || size % 2) return false;
    std::vector<uint8_t> terminated(data, data + size);
    terminated.push_back(0); terminated.push_back(0);
    if (!RdpClipboardCodec::decode(terminated.data(), terminated.size(), path)) return false;
    std::replace(path.begin(), path.end(), '\\', '/');
    if (!path.empty() && path.front() == '/') path.erase(0, 1);
    if (path.empty()) return true;
    if (path.front() == '/' || path.find(':') != std::string::npos) return false;
    size_t pos = 0;
    while (pos < path.size()) {
        const size_t end = path.find('/', pos);
        const auto component = path.substr(pos, end == std::string::npos ? end : end - pos);
        if (component.empty() || component == "." || component == "..") return false;
        if (end == std::string::npos) break;
        pos = end + 1;
    }
    return true;
}
}
void RdpChannelObserver::reset(uint64_t generation) {
    std::lock_guard<std::mutex> lock(mutex_);
    status_ = {}; status_.generation = generation; status_.phase = "waitingChannel";
    devices_.clear(); requests_.clear(); handles_.clear(); facts_.clear();
    prefix_.clear(); fragmenting_ = false; received_ = expected_ = 0; change_ = 0; unavailable_ = false;
}
void RdpChannelObserver::registered(uint32_t deviceId) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (unavailable_) return;
    status_.deviceId = deviceId;
    if (devices_.size() >= 32 && !devices_.count(deviceId)) { incomplete(); return; }
    (void)devices_[deviceId]; updatePhase();
}
void RdpChannelObserver::unavailable(const std::string& reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    status_.phase = "unavailable"; status_.diagnosticCode = reason; unavailable_ = true;
    if (status_.deviceId) devices_[status_.deviceId].removed = true;
    requests_.clear(); handles_.clear(); prefix_.clear(); fragmenting_ = false;
    for (auto& item : facts_) { item.second.uncertain = true; item.second.remoteClosed = false; }
}
void RdpChannelObserver::markUncertain() noexcept {
    std::lock_guard<std::mutex> lock(mutex_); incomplete();
}
void RdpChannelObserver::incomplete() {
    status_.evidenceComplete = false;
    for (auto& item : facts_) { item.second.uncertain = true; item.second.remoteClosed = false; }
}
void RdpChannelObserver::updatePhase() {
    if (!status_.deviceId) return;
    const auto& device = devices_[status_.deviceId];
    status_.serverStatus = device.status;
    status_.phase = device.removed ? "unavailable" : device.replied ?
        (device.status == 0 ? "serverAccepted" : "rejected") :
        device.announced ? "announceSent" : "localRegistered";
    status_.diagnosticCode = device.replied && device.status != 0 ? "server_rejected_drive" : "";
}
RdpDriveStatus RdpChannelObserver::status() const { std::lock_guard<std::mutex> lock(mutex_); return status_; }
std::vector<RdpReceivedFileFact> RdpChannelObserver::files() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RdpReceivedFileFact> result;
    for (const auto& entry : facts_) if (!entry.first.empty()) result.push_back(entry.second);
    return result;
}
void RdpChannelObserver::receive(const uint8_t* bytes, size_t size, uint32_t flags, size_t totalSize) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!bytes && size) { incomplete(); return; }
    if ((flags & 0x60) != 0) { fragmenting_ = false; prefix_.clear(); incomplete(); return; }
    if (flags & 1) {
        if (fragmenting_) incomplete();
        prefix_.clear(); received_ = 0; expected_ = totalSize; fragmenting_ = true;
    }
    if (!fragmenting_ || expected_ != totalSize || received_ > expected_ || size > expected_ - received_) {
        incomplete(); fragmenting_ = false; prefix_.clear(); return;
    }
    const size_t keep = std::min(size, kPrefixBudget - prefix_.size());
    if (keep) prefix_.insert(prefix_.end(), bytes, bytes + keep);
    received_ += size;
    if (flags & 2) {
        if (received_ == expected_) packet(prefix_.data(), prefix_.size(), received_, false);
        else incomplete();
        fragmenting_ = false; prefix_.clear();
    }
}
void RdpChannelObserver::sent(const uint8_t* bytes, size_t size) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!bytes && size) { incomplete(); return; }
    packet(bytes, std::min(size, kPrefixBudget), size, true);
}
void RdpChannelObserver::packet(const uint8_t* bytes, size_t size, size_t total, bool outgoing) {
    if (unavailable_ || size < 4 || u16(bytes) != kCore) return;
    const auto type = u16(bytes + 2);
    if (outgoing && type == kAnnounce) {
        if (size < 8 || u32(bytes + 4) > 32) { incomplete(); return; }
        size_t pos = 8;
        for (uint32_t i = 0; i < u32(bytes + 4); ++i) {
            if (size - pos < 20) { incomplete(); return; }
            const uint32_t id = u32(bytes + pos + 4), len = u32(bytes + pos + 16);
            if (len > size - pos - 20) { incomplete(); return; }
            if (u32(bytes + pos) == 8) {
                if (devices_.size() >= 32 && !devices_.count(id)) { incomplete(); return; }
                auto& device = devices_[id]; device.announced = true; device.removed = false;
            }
            pos += 20 + len;
        }
        updatePhase();
    } else if (!outgoing && type == kReply) {
        if (size != 12 || total != 12) { incomplete(); return; }
        auto it = devices_.find(u32(bytes + 4));
        if (it != devices_.end() && it->second.announced) {
            it->second.replied = true; it->second.status = u32(bytes + 8); updatePhase();
        }
    } else if (outgoing && type == kRemove) {
        if (size < 8 || u32(bytes + 4) > (size - 8) / 4) { incomplete(); return; }
        for (uint32_t i = 0; i < u32(bytes + 4); ++i) {
            auto it = devices_.find(u32(bytes + 8 + 4 * i));
            if (it != devices_.end()) it->second.removed = true;
        }
        updatePhase(); incomplete();
    } else if (!outgoing && type == kRequest && size >= 24 && u32(bytes + 4) == status_.deviceId) {
        if (status_.phase != "serverAccepted") { incomplete(); return; }
        Request request;
        request.fileId = u32(bytes + 8); request.major = u32(bytes + 16);
        const uint32_t completionId = u32(bytes + 12);
        if (requests_.size() >= kRequestBudget || requests_.count(completionId)) { incomplete(); return; }
        if (request.major == kCreate) {
            if (size < 56 || u32(bytes + 52) > size - 56 ||
                !observedPath(bytes + 56, u32(bytes + 52), request.path)) { incomplete(); return; }
        } else if (request.major == kWrite) {
            if (size < 56 || u32(bytes + 24) > total - 56) { incomplete(); return; }
            request.bytes = u32(bytes + 24);
        } else if (request.major == kSetInformation) {
            if (size < 56) { incomplete(); return; }
            if (u32(bytes + 24) == 10) { // FileRenameInformation
                if (size < 62 || u32(bytes + 58) > size - 62 ||
                    !observedPath(bytes + 62, u32(bytes + 58), request.rename)) { incomplete(); return; }
            }
        } else if (request.major != kClose) return;
        requests_.emplace(completionId, std::move(request));
    } else if (outgoing && type == kCompletion && size >= 16 && u32(bytes + 4) == status_.deviceId) {
        completion(bytes, size);
    }
}
void RdpChannelObserver::completion(const uint8_t* bytes, size_t size) {
    const auto found = requests_.find(u32(bytes + 8));
    if (found == requests_.end()) return;
    auto request = std::move(found->second); requests_.erase(found);
    if (u32(bytes + 12) != 0) return;
    if (request.major == kCreate) {
        if (size < 20 || facts_.size() >= kFactBudget || handles_.size() >= kFactBudget) { incomplete(); return; }
        const uint32_t fileId = u32(bytes + 16);
        if (handles_.count(fileId)) { incomplete(); return; }
        handles_[fileId] = request.path;
        auto& fact = facts_[request.path]; fact.relativePath = request.path;
        ++fact.activeHandles; fact.remoteClosed = false; fact.uncertain = !status_.evidenceComplete;
        fact.writeGeneration = ++change_;
        return;
    }
    auto handle = handles_.find(request.fileId);
    if (handle == handles_.end()) { incomplete(); return; }
    auto& fact = facts_[handle->second];
    if (request.major == kClose) {
        if (fact.activeHandles) --fact.activeHandles;
        fact.remoteClosed = fact.activeHandles == 0 && !fact.uncertain;
        handles_.erase(handle);
    } else if (request.major == kWrite) {
        if (size < 20 || u32(bytes + 16) > request.bytes) { incomplete(); return; }
        const uint32_t count = u32(bytes + 16);
        if (count > std::numeric_limits<uint64_t>::max() - fact.writtenBytes) { incomplete(); return; }
        fact.writtenBytes += count; fact.writeGeneration = ++change_; fact.remoteClosed = false;
    } else if (request.major == kSetInformation) {
        fact.writeGeneration = ++change_; fact.remoteClosed = false;
        if (!request.rename.empty() && request.rename != handle->second) {
            if (facts_.count(request.rename) || facts_.size() >= kFactBudget) { incomplete(); return; }
            for (const auto& entry : facts_) {
                if (entry.first.compare(0, handle->second.size() + 1, handle->second + "/") == 0) {
                    incomplete(); break;
                }
            }
            auto moved = fact; moved.relativePath = request.rename;
            const auto previous = handle->second;
            facts_.erase(previous); facts_[request.rename] = std::move(moved);
            for (auto& item : handles_) if (item.second == previous) item.second = request.rename;
        }
    }
}
