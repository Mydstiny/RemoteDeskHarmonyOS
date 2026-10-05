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
//
// ArkTS talks to a session, not to a broker: a reconnect replaces the broker of an RDP context, while the
// watcher, request IDs and notifications (release, dismiss, touch) belong to the session and survive it.
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
    Dismiss = 8,   // notification only: id = a delivered prompt that ended unanswered (timeout, cancel, close)
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
constexpr uint32_t kReadGraceMs = 1500;
// A remote request's own timeout bounds its prompts, within these limits.
constexpr uint32_t kMinRequestMs = 10000;
constexpr uint32_t kMaxRequestMs = 600000;
constexpr uint32_t kNoDeadline = UINT32_MAX;
constexpr size_t kMaxRpIdLength = 253;
// CTAP2 client PIN: at least 4 Unicode code points, at most 63 bytes of UTF-8.
constexpr size_t kMinPinCodePoints = 4;
constexpr size_t kMaxPinBytes = 63;
// Key names end up in fixed 64-byte fields of the channel reply.
constexpr size_t kMaxProductBytes = 63;

class Broker final {
public:
    Broker(uint64_t sessionId, uint64_t generation);
    ~Broker();
    Broker(const Broker&) = delete;
    Broker& operator=(const Broker&) = delete;

    uint64_t SessionId() const { return sessionId_; }
    // Process-unique; names this broker in the libfido2 device path.
    uint64_t Generation() const { return generation_; }

    // Channel side. Begin starts a remote request: it clears the previous cancellation and bounds the request's
    // prompts by timeoutMs (0: the per-prompt bounds only). It fails once the broker is closed.
    bool Begin(uint32_t timeoutMs = 0);
    // Milliseconds left before the request deadline, or kNoDeadline.
    uint32_t RemainingMs() const;
    bool Confirm(const std::string& rpId, uint32_t operation);
    bool Select(std::string& product);
    bool Authorized(std::string& product) const;
    // The authorized key could not be opened: forget it and have ArkTS release it.
    void Forget();
    std::optional<std::string> Pin(int32_t retries);
    void Touch(bool waiting);
    bool WriteReport(const std::array<uint8_t, 64>& report);
    bool ReadReport(std::array<uint8_t, 64>& report, int timeoutMs);
    void Cancel();
    // True when a key was authorized: whoever retires the broker has the session release it.
    bool Close();
    bool Cancelled() const;
    bool Closed() const;
    void OnCancelChanged(std::function<void(bool)> listener);

    // ArkTS side, reached through the session functions below.
    bool Poll(Request& request);
    bool Respond(uint32_t id, const Reply& reply);
    bool HasUndelivered() const;
    // ArkTS released the key on its own (Pro revoked, page closed).
    void Unauthorize();

private:
    std::optional<Reply> Exchange(Request request, std::chrono::milliseconds timeout, bool userFacing);
    std::chrono::milliseconds UntilDeadline() const;
    void Wake(std::unique_lock<std::mutex>& lock);
    void SetCancelled(std::unique_lock<std::mutex>& lock, bool cancelled);

    const uint64_t sessionId_;
    const uint64_t generation_;
    mutable std::mutex mutex_;
    std::condition_variable changed_;
    bool closed_ = false;
    bool cancelled_ = false;
    bool authorized_ = false;
    std::string product_;
    std::chrono::steady_clock::time_point deadline_ = std::chrono::steady_clock::time_point::max();
    std::optional<Request> pending_;
    bool delivered_ = false;
    std::optional<Reply> reply_;
    std::function<void(bool)> cancelListener_;
};

// Adapter and channel side: a broker per RDP context.
std::shared_ptr<Broker> Attach(const void* context, uint64_t sessionId);
std::shared_ptr<Broker> ForContext(const void* context);
std::shared_ptr<Broker> ForGeneration(uint64_t generation);
// The open broker of a session, if any.
std::shared_ptr<Broker> ForSession(uint64_t sessionId);
void Close(const void* context);
void Detach(const void* context);

// ArkTS side, per session. Watch fails when the session has no open broker; the watcher then stays installed
// across reconnects until Unwatch. Poll delivers Release and Dismiss first, then the pending request, then Touch.
bool Watch(uint64_t sessionId, std::function<void()> wake);
void Unwatch(uint64_t sessionId);
bool Poll(uint64_t sessionId, Request& request);
bool Respond(uint64_t sessionId, uint32_t id, const Reply& reply);
void Cancel(uint64_t sessionId);
void Released(uint64_t sessionId);

// Exposed for tests: replaces control characters and bounds a relying party ID for display.
std::string SanitizeRpId(const std::string& rpId);
// Exposed for tests: printable, valid UTF-8, at most limit bytes, never cut inside a character.
std::string SanitizeLabel(const std::string& value, size_t limit);
// Exposed for tests: the CTAP2 PIN rules above.
bool ValidPin(const std::string& pin);

} // namespace RdpSecurityKey
