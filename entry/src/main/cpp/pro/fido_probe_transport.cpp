#include "fido_probe_transport.h"

#include <fido.h>
#include <algorithm>
#include <cstring>

namespace ProFido {
namespace {
thread_local ProbeTransport* openingProbe = nullptr;
constexpr const char* kProbePath = "remotedesk-debug-usb-capability-probe";
uint32_t Channel(const uint8_t* bytes) {
    return (uint32_t(bytes[0]) << 24) | (uint32_t(bytes[1]) << 16) |
        (uint32_t(bytes[2]) << 8) | uint32_t(bytes[3]);
}
} // namespace

ProbeTransport::ProbeTransport(std::chrono::milliseconds budget)
    : budget_(std::clamp(budget, std::chrono::milliseconds(1), std::chrono::milliseconds(5000))),
      deadline_(std::chrono::steady_clock::now() + budget_) {
    try { worker_ = std::thread(&ProbeTransport::Run, this); }
    catch (...) { status_ = ProbeStatus::Failed; finished_.store(true, std::memory_order_release); }
}

ProbeTransport::~ProbeTransport() {
    Cancel();
    if (worker_.joinable()) worker_.join();
}

bool ProbeTransport::CurrentLocked() const {
    return status_ == ProbeStatus::Running && std::chrono::steady_clock::now() < deadline_;
}

void ProbeTransport::Cancel() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (status_ == ProbeStatus::Running) status_ = ProbeStatus::Cancelled;
    changed_.notify_all();
}

ProbeSnapshot ProbeTransport::Poll() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (status_ == ProbeStatus::Running && !CurrentLocked()) {
        status_ = ProbeStatus::Failed;
        changed_.notify_all();
    }
    ProbeSnapshot snapshot;
    snapshot.status = status_;
    if (CurrentLocked() && pending_.id != 0 && !delivered_) {
        delivered_ = true;
        snapshot.request = pending_;
    }
    return snapshot;
}

bool ProbeTransport::Reply(uint32_t requestId, const uint8_t* bytes, size_t length, bool success) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!CurrentLocked() || !delivered_ || replied_ || requestId == 0 || requestId != pending_.id) return false;
    replySucceeded_ = success && bytes != nullptr && length == reply_.size();
    if (replySucceeded_) {
        std::copy_n(bytes, reply_.size(), reply_.begin());
        if (pending_.write && reply_ != pending_.report) replySucceeded_ = false;
    }
    replied_ = true;
    changed_.notify_all();
    return true;
}

bool ProbeTransport::Exchange(bool write, std::array<uint8_t, 64>& report, int timeoutMs) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!CurrentLocked() || pending_.id != 0 || ++nextRequest_ > 304) return false;
    const auto limit = std::min(deadline_, std::chrono::steady_clock::now() +
        std::chrono::milliseconds(std::clamp(timeoutMs, 1, 1500)));
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        limit - std::chrono::steady_clock::now()).count();
    if (remaining < 1) return false;
    pending_ = {nextRequest_, write, static_cast<uint32_t>(remaining), report};
    delivered_ = false;
    replied_ = false;
    replySucceeded_ = false;
    changed_.wait_until(lock, limit, [this] { return replied_ || status_ != ProbeStatus::Running; });
    const bool accepted = CurrentLocked() && replied_ && replySucceeded_;
    if (accepted) report = reply_;
    pending_ = {};
    if (!accepted && status_ == ProbeStatus::Running) status_ = ProbeStatus::Failed;
    return accepted;
}

void* ProbeTransport::Open(const char* path) {
    if (openingProbe == nullptr || path == nullptr || std::strcmp(path, kProbePath) != 0 ||
        openingProbe->opened_) return nullptr;
    std::lock_guard<std::mutex> lock(openingProbe->mutex_);
    if (!openingProbe->CurrentLocked()) return nullptr;
    openingProbe->opened_ = true;
    return openingProbe;
}

void ProbeTransport::Close(void* handle) {
    if (handle != nullptr) static_cast<ProbeTransport*>(handle)->opened_ = false;
}

int ProbeTransport::Write(void* handle, const unsigned char* bytes, size_t length) {
    auto* probe = static_cast<ProbeTransport*>(handle);
    // libfido2 includes an unnumbered report-ID byte. USBManager receives only
    // the actual 64-byte report, and can never receive a numbered HID report.
    if (probe == nullptr || bytes == nullptr || length != 65 || bytes[0] != 0) return -1;
    std::array<uint8_t, 64> report{};
    std::copy_n(bytes + 1, report.size(), report.begin());
    const auto channel = Channel(report.data());
    if (!probe->initSent_) {
        if (channel != UINT32_MAX || report[4] != 0x86 || report[5] != 0 || report[6] != 8) return -1;
        std::copy_n(report.begin() + 7, probe->nonce_.size(), probe->nonce_.begin());
        probe->initSent_ = true;
    } else {
        // Capability verification has no signing, registration, PIN, reset,
        // credential-management or vendor command entry point.
        if (probe->infoWrites_ >= 2 || probe->channel_ == 0 || channel != probe->channel_ ||
            report[4] != 0x90 || report[5] != 0 || report[6] != 1 || report[7] != 0x04) return -1;
        ++probe->infoWrites_;
    }
    return probe->Exchange(true, report, 1500) ? 65 : -1;
}

int ProbeTransport::Read(void* handle, unsigned char* bytes, size_t length, int timeoutMs) {
    auto* probe = static_cast<ProbeTransport*>(handle);
    if (probe == nullptr || bytes == nullptr || length != 64 || timeoutMs <= 0 ||
        !probe->initSent_ || ++probe->readCount_ > 300) return -1;
    std::array<uint8_t, 64> report{};
    if (!probe->Exchange(false, report, timeoutMs)) return -1;
    const auto channel = Channel(report.data());
    if (probe->channel_ == 0 && channel == UINT32_MAX) {
        if (report[4] != 0x86 || report[5] != 0 || report[6] != 17 ||
            !std::equal(probe->nonce_.begin(), probe->nonce_.end(), report.begin() + 7) ||
            report[19] != 2 || (report[23] & 4) == 0) return -1;
        const auto assigned = Channel(report.data() + 15);
        if (assigned == 0 || assigned == UINT32_MAX) return -1;
        probe->channel_ = assigned;
    }
    if (channel == probe->channel_ && (report[4] & 0x80) != 0 &&
        (uint32_t(report[5]) * 256 + report[6]) > 7609) return -1;
    std::copy(report.begin(), report.end(), bytes);
    return 64;
}

void ProbeTransport::Run() {
    openingProbe = this;
    fido_init(FIDO_DISABLE_U2F_FALLBACK);
    fido_dev_t* device = fido_dev_new();
    const fido_dev_io_t io = {Open, Close, Read, Write};
    bool success = false;
    if (device != nullptr && fido_dev_set_io_functions(device, &io) == FIDO_OK &&
        fido_dev_set_timeout(device, static_cast<int>(budget_.count())) == FIDO_OK &&
        fido_dev_open(device, kProbePath) == FIDO_OK) {
        // Open consumes an internal GetInfo. Read capabilities explicitly too:
        // an empty CBOR map must not count as a supported FIDO2 authenticator.
        fido_cbor_info_t* info = fido_cbor_info_new();
        if (info != nullptr && fido_dev_is_fido2(device) &&
            fido_dev_get_cbor_info(device, info) == FIDO_OK) {
            const auto count = fido_cbor_info_versions_len(info);
            const auto versions = fido_cbor_info_versions_ptr(info);
            for (size_t i = 0; versions != nullptr && count <= 32 && i < count; ++i) {
                if (versions[i] != nullptr &&
                    (std::strcmp(versions[i], "FIDO_2_0") == 0 || std::strcmp(versions[i], "FIDO_2_1") == 0 ||
                     std::strcmp(versions[i], "FIDO_2_2") == 0 || std::strcmp(versions[i], "FIDO_2_3") == 0)) {
                    success = infoWrites_ == 2 && channel_ != 0;
                }
            }
        }
        fido_cbor_info_free(&info);
    }
    if (device != nullptr) {
        if (opened_) (void)fido_dev_close(device);
        fido_dev_free(&device);
    }
    openingProbe = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (status_ == ProbeStatus::Running) {
            status_ = success && CurrentLocked() ? ProbeStatus::Success : ProbeStatus::Failed;
        }
        pending_ = {};
    }
    finished_.store(true, std::memory_order_release);
}

} // namespace ProFido
