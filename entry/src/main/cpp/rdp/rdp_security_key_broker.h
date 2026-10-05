#pragma once

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

// Session-bound broker between the MS-RDPEWA channel worker (native threads) and the ArkTS owner of the
// local UI and of USB I/O. One request is outstanding at a time; every wait is bounded; Close() makes every
// current and future wait fail at once, so channel teardown can always join its worker.
namespace RdpSecurityKey {

enum class Kind : uint32_t {
    None = 0,
    Confirm = 1,   // text = relying party ID, operation = 1 register / 2 sign in
    Select = 2,    // authorize one USB security key; reply text = display name
    Pin = 3,       // retries = remaining PIN attempts or -1; reply text = PIN
    Touch = 4,     // notification only: operation = 1 show / 0 hide the touch prompt
    Write = 5,     // report = one 64-byte HID output report
    Read = 6,      // timeoutMs bounds one 64-byte HID input report; reply report
    Release = 7,   // notification only: release the authorized key
};

struct Request {
    uint32_t id = 0;
    Kind kind = Kind::None;
    std::string text;
    uint32_t operation = 0;
    int32_t retries = -1;
    uint32_t timeoutMs = 0;
    std::array<uint8_t, 64> report{};
};

struct Reply {
    bool ok = false;
    std::string text;
    std::array<uint8_t, 64> report{};
};

constexpr std::chrono::milliseconds kConfirmTimeout{60000};
constexpr std::chrono::milliseconds kSelectTimeout{120000};
constexpr std::chrono::milliseconds kPinTimeout{120000};
constexpr std::chrono::milliseconds kWriteTimeout{2000};
constexpr uint32_t kMaxReadMs = 5000;
constexpr size_t kMaxRpIdLength = 253;
constexpr size_t kMaxPinBytes = 255;

class Broker final {
public:
    explicit Broker(uint64_t sessionId);
    ~Broker();
    Broker(const Broker&) = delete;
    Broker& operator=(const Broker&) = delete;

    uint64_t SessionId() const { return sessionId_; }

    // Channel side. Begin clears the previous cancellation; it fails once the broker is closed.
    bool Begin();
    bool Confirm(const std::string& rpId, uint32_t operation);
    bool Select(std::string& product);
    bool Authorized(std::string& product) const;
    void Forget();
    std::optional<std::string> Pin(int32_t retries);
    void Touch(bool waiting);
    bool WriteReport(const std::array<uint8_t, 64>& report);
    bool ReadReport(std::array<uint8_t, 64>& report, int timeoutMs);
    void Cancel();
    void Close();
    bool Cancelled() const;
    bool Closed() const;
    void OnCancelChanged(std::function<void(bool)> listener);

    // ArkTS side.
    bool Poll(Request& request);
    bool Respond(uint32_t id, const Reply& reply);
    void SetWake(std::function<void()> wake);

private:
    std::optional<Reply> Exchange(Request request, std::chrono::milliseconds timeout, bool userFacing);
    void Notify(Kind kind, uint32_t operation);
    void Wake(std::unique_lock<std::mutex>& lock);
    void SetCancelled(std::unique_lock<std::mutex>& lock, bool cancelled);

    const uint64_t sessionId_;
    mutable std::mutex mutex_;
    std::condition_variable changed_;
    bool closed_ = false;
    bool cancelled_ = false;
    bool authorized_ = false;
    std::string product_;
    uint32_t nextId_ = 0;
    std::optional<Request> pending_;
    bool delivered_ = false;
    std::optional<Reply> reply_;
    // Notifications are delivered after the pending request; only the latest of each kind matters.
    std::optional<Request> touch_;
    std::optional<Request> release_;
    std::function<void()> wake_;
    std::function<void(bool)> cancelListener_;
};

// Registry: the adapter attaches a broker to an RDP context; the channel finds it by context and ArkTS by session.
std::shared_ptr<Broker> Attach(const void* context, uint64_t sessionId);
std::shared_ptr<Broker> ForContext(const void* context);
std::shared_ptr<Broker> ForSession(uint64_t sessionId);
void Close(const void* context);
void Detach(const void* context);

// Exposed for tests: replaces control characters and bounds a relying party ID for display.
std::string SanitizeRpId(const std::string& rpId);

} // namespace RdpSecurityKey
