#pragma once

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>

namespace ProFido {

enum class ProbeStatus : uint32_t { Running = 0, Success = 1, Failed = 2, Cancelled = 3, Invalid = 4 };

struct ProbeRequest {
    uint32_t id = 0;
    bool write = false;
    uint32_t timeoutMs = 0;
    std::array<uint8_t, 64> report{};
};

struct ProbeSnapshot {
    ProbeStatus status = ProbeStatus::Invalid;
    ProbeRequest request{};
};

// A single library INIT/GetInfo transaction. It has no USB/device-opening code:
// the authorized ArkTS owner performs each bounded 64-byte interrupt transfer.
// Destruction cancels all waits and joins before any library object is freed.
class ProbeTransport final {
public:
    explicit ProbeTransport(std::chrono::milliseconds budget = std::chrono::milliseconds(5000));
    ~ProbeTransport();
    ProbeTransport(const ProbeTransport&) = delete;
    ProbeTransport& operator=(const ProbeTransport&) = delete;

    ProbeSnapshot Poll();
    bool Reply(uint32_t requestId, const uint8_t* bytes, size_t length, bool success);
    void Cancel();
    bool Finished() const { return finished_.load(std::memory_order_acquire); }

private:
    static void* Open(const char* path);
    static void Close(void* handle);
    static int Read(void* handle, unsigned char* bytes, size_t length, int timeoutMs);
    static int Write(void* handle, const unsigned char* bytes, size_t length);
    bool Exchange(bool write, std::array<uint8_t, 64>& report, int timeoutMs);
    void Run();
    bool CurrentLocked() const;

    const std::chrono::milliseconds budget_;
    const std::chrono::steady_clock::time_point deadline_;
    std::mutex mutex_;
    std::condition_variable changed_;
    ProbeStatus status_ = ProbeStatus::Running;
    ProbeRequest pending_{};
    bool delivered_ = false;
    bool replied_ = false;
    bool replySucceeded_ = false;
    std::array<uint8_t, 64> reply_{};
    uint32_t nextRequest_ = 0;
    std::atomic<bool> finished_{false};
    std::thread worker_;

    // Used only by the library worker, never by the ArkTS polling thread.
    bool opened_ = false;
    bool initSent_ = false;
    unsigned infoWrites_ = 0;
    uint32_t channel_ = 0;
    unsigned readCount_ = 0;
    std::array<uint8_t, 8> nonce_{};
};

} // namespace ProFido
