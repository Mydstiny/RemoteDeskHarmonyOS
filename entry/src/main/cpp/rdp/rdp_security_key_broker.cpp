#include "rdp_security_key_broker.h"

#include <algorithm>
#include <atomic>
#include <map>

namespace RdpSecurityKey {
namespace {
constexpr size_t kMaxCtapMessage = 7609;
using Clock = std::chrono::steady_clock;

void Wipe(std::string& value) {
    std::fill(value.begin(), value.end(), '\0');
    value.clear();
}

// Decodes one UTF-8 character at value[index]; 0 when the bytes there are not a valid, shortest-form character.
size_t Utf8Length(const std::string& value, size_t index, uint32_t& codePoint) {
    const auto lead = static_cast<unsigned char>(value[index]);
    size_t length = 0;
    if (lead < 0x80) {
        codePoint = lead;
        return 1;
    }
    if (lead >= 0xc2 && lead <= 0xdf) {
        length = 2;
        codePoint = lead & 0x1f;
    } else if (lead >= 0xe0 && lead <= 0xef) {
        length = 3;
        codePoint = lead & 0x0f;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
        length = 4;
        codePoint = lead & 0x07;
    } else {
        return 0;
    }
    if (index + length > value.size()) return 0;
    for (size_t k = 1; k < length; ++k) {
        const auto next = static_cast<unsigned char>(value[index + k]);
        if ((next & 0xc0) != 0x80) return 0;
        codePoint = (codePoint << 6) | (next & 0x3f);
    }
    if ((length == 3 && (codePoint < 0x800 || (codePoint >= 0xd800 && codePoint <= 0xdfff))) ||
        (length == 4 && (codePoint < 0x10000 || codePoint > 0x10ffff))) {
        return 0;
    }
    return length;
}

// Session state that outlives brokers: the ArkTS watcher and the notifications still owed to it.
struct Session {
    std::function<void()> wake;
    bool release = false;
    std::optional<uint32_t> dismiss;
    std::optional<uint32_t> touch;
};

std::mutex g_registryMutex;
std::map<const void*, std::shared_ptr<Broker>> g_brokers;
std::map<uint64_t, Session> g_sessions;
std::atomic<uint64_t> g_lastGeneration{0};
// Request IDs are unique in the process, so a late answer can never match a newer broker's request.
std::atomic<uint32_t> g_lastRequestId{0};

uint32_t NextRequestId() {
    uint32_t id = ++g_lastRequestId;
    while (id == 0) id = ++g_lastRequestId;
    return id;
}

Request Notification(Kind kind, uint32_t operation, uint32_t id) {
    Request request;
    request.kind = kind;
    request.operation = operation;
    request.id = id;
    return request;
}

std::shared_ptr<Broker> OpenLocked(uint64_t sessionId) {
    // A reconnect attaches the new context before the old one is detached; the open broker wins.
    for (const auto& entry : g_brokers) {
        if (entry.second && entry.second->SessionId() == sessionId && !entry.second->Closed()) return entry.second;
    }
    return nullptr;
}

void PruneLocked(uint64_t sessionId) {
    const auto found = g_sessions.find(sessionId);
    if (found == g_sessions.end() || found->second.wake) return;
    for (const auto& entry : g_brokers) {
        if (entry.second && entry.second->SessionId() == sessionId) return;
    }
    g_sessions.erase(found);
}

void WakeSession(uint64_t sessionId) {
    std::function<void()> wake;
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        const auto found = g_sessions.find(sessionId);
        if (found != g_sessions.end()) wake = found->second.wake;
    }
    if (wake) wake();
}

// Queues a notification for the session's watcher. Only the latest of each kind matters.
void Post(uint64_t sessionId, Kind kind, uint32_t value) {
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        const auto found = g_sessions.find(sessionId);
        if (found == g_sessions.end()) return;
        Session& session = found->second;
        if (kind == Kind::Release) session.release = true;
        else if (kind == Kind::Dismiss) session.dismiss = value;
        else if (kind == Kind::Touch) session.touch = value;
        else return;
    }
    WakeSession(sessionId);
}

void Retire(const std::shared_ptr<Broker>& broker) {
    if (broker && broker->Close()) Post(broker->SessionId(), Kind::Release, 0);
}
} // namespace

std::string SanitizeRpId(const std::string& rpId) {
    // Relying party IDs are DNS names (IDNA A-labels) or the literal "localhost"; anything else is shown escaped.
    std::string clean;
    for (const char raw : rpId) {
        const auto c = static_cast<unsigned char>(raw);
        clean.push_back(c >= 0x21 && c <= 0x7e ? raw : '?');
        if (clean.size() >= kMaxRpIdLength) break;
    }
    return clean;
}

std::string SanitizeLabel(const std::string& value, size_t limit) {
    std::string clean;
    size_t index = 0;
    while (index < value.size()) {
        uint32_t codePoint = 0;
        const size_t length = Utf8Length(value, index, codePoint);
        if (length == 0) {
            ++index;
            continue;
        }
        const bool control = codePoint < 0x20 || (codePoint >= 0x7f && codePoint <= 0x9f);
        if (!control) {
            if (clean.size() + length > limit) break;
            clean.append(value, index, length);
        }
        index += length;
    }
    return clean;
}

bool ValidPin(const std::string& pin) {
    if (pin.size() > kMaxPinBytes) return false;
    size_t codePoints = 0;
    for (size_t index = 0; index < pin.size(); ++codePoints) {
        uint32_t codePoint = 0;
        const size_t length = Utf8Length(pin, index, codePoint);
        if (length == 0 || codePoint == 0) return false;
        index += length;
    }
    return codePoints >= kMinPinCodePoints;
}

Broker::Broker(uint64_t sessionId, uint64_t generation) : sessionId_(sessionId), generation_(generation) {}

Broker::~Broker() { Close(); }

void Broker::SetCancelled(std::unique_lock<std::mutex>&, bool cancelled) {
    if (cancelled_ == cancelled) return;
    cancelled_ = cancelled;
    if (cancelListener_) cancelListener_(cancelled);
}

void Broker::Wake(std::unique_lock<std::mutex>& lock) {
    lock.unlock();
    WakeSession(sessionId_);
    lock.lock();
}

bool Broker::Begin(uint32_t timeoutMs) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (closed_) return false;
    SetCancelled(lock, false);
    deadline_ = timeoutMs == 0 ? Clock::time_point::max() :
        Clock::now() + std::chrono::milliseconds(std::clamp(timeoutMs, kMinRequestMs, kMaxRequestMs));
    return true;
}

std::chrono::milliseconds Broker::UntilDeadline() const {
    if (deadline_ == Clock::time_point::max()) return std::chrono::milliseconds::max();
    const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline_ - Clock::now());
    return std::max(left, std::chrono::milliseconds(0));
}

uint32_t Broker::RemainingMs() const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto left = UntilDeadline();
    if (left == std::chrono::milliseconds::max()) return kNoDeadline;
    return static_cast<uint32_t>(std::min<int64_t>(left.count(), kNoDeadline - 1));
}

void Broker::Cancel() {
    std::unique_lock<std::mutex> lock(mutex_);
    SetCancelled(lock, true);
    changed_.notify_all();
}

bool Broker::Close() {
    std::unique_lock<std::mutex> lock(mutex_);
    if (closed_) return false;
    closed_ = true;
    SetCancelled(lock, true);
    // Only a USB key is held by ArkTS; the phone holds nothing for this session.
    const bool authorized = authorized_ && authenticator_ == Authenticator::UsbKey;
    authorized_ = false;
    authenticator_ = Authenticator::None;
    Wipe(product_);
    changed_.notify_all();
    return authorized;
}

bool Broker::Cancelled() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return cancelled_;
}

bool Broker::Closed() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_;
}

void Broker::OnCancelChanged(std::function<void(bool)> listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    cancelListener_ = std::move(listener);
    if (cancelListener_) cancelListener_(cancelled_);
}

bool Broker::HasUndelivered() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return pending_.has_value() && !delivered_;
}

std::optional<Reply> Broker::Exchange(Request request, std::chrono::milliseconds timeout, bool userFacing) {
    std::unique_lock<std::mutex> lock(mutex_);
    const auto stopped = [&]() { return closed_ || (userFacing && cancelled_); };
    // Prompts end with the remote request; device I/O (including the CTAPHID_CANCEL write) never does.
    if (userFacing) timeout = std::min(timeout, UntilDeadline());
    if (stopped() || timeout <= std::chrono::milliseconds(0)) return std::nullopt;
    const auto until = Clock::now() + timeout;
    // A single channel worker drives the protocol, so this only waits out a request that is finishing.
    if (!changed_.wait_until(lock, until, [&]() { return stopped() || !pending_; }) || stopped()) {
        return std::nullopt;
    }
    request.id = NextRequestId();
    pending_ = request;
    delivered_ = false;
    reply_.reset();
    Wake(lock);
    const bool answered = changed_.wait_until(lock, until, [&]() { return stopped() || reply_.has_value(); });
    std::optional<Reply> result;
    if (answered && reply_ && !stopped()) result = reply_;
    // ArkTS saw this prompt but its answer no longer counts: tell it to take the prompt down.
    const bool dismiss = userFacing && delivered_ && !result;
    if (reply_) Wipe(reply_->text);
    pending_.reset();
    reply_.reset();
    delivered_ = false;
    changed_.notify_all();
    if (dismiss) {
        lock.unlock();
        Post(sessionId_, Kind::Dismiss, request.id);
    }
    return result;
}

bool Broker::Poll(Request& request) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_ || !pending_ || delivered_) return false;
    request = *pending_;
    delivered_ = true;
    return true;
}

bool Broker::Respond(uint32_t id, const Reply& reply) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_ || !pending_ || !delivered_ || reply_ || pending_->id != id) return false;
    Reply accepted = reply;
    if (pending_->kind != Kind::Passkey) accepted.payload.clear();
    switch (pending_->kind) {
        case Kind::Confirm:
        case Kind::Write:
            Wipe(accepted.text);
            break;
        case Kind::Select:
            accepted.text = SanitizeLabel(accepted.text, kMaxProductBytes);
            if (accepted.authenticator != Authenticator::UsbKey && accepted.authenticator != Authenticator::Phone) {
                accepted.ok = false;
            }
            break;
        case Kind::Passkey:
            Wipe(accepted.text);
            // A CTAP response: one status byte, then the CBOR body when the status is success.
            if (accepted.ok && (accepted.payload.empty() || accepted.payload.size() > kMaxPasskeyReplyBytes)) {
                accepted.ok = false;
            }
            if (!accepted.ok) accepted.payload.clear();
            break;
        case Kind::Pin:
            if (!ValidPin(accepted.text)) accepted.ok = false;
            break;
        case Kind::Read:
            Wipe(accepted.text);
            // An initialization frame never declares more than a full CTAP HID message.
            if (accepted.ok && (accepted.report[4] & 0x80) != 0 &&
                (size_t(accepted.report[5]) << 8 | accepted.report[6]) > kMaxCtapMessage) {
                accepted.ok = false;
            }
            break;
        default:
            Wipe(accepted.text);
            return false;
    }
    if (!accepted.ok) Wipe(accepted.text);
    reply_ = accepted;
    Wipe(accepted.text);
    changed_.notify_all();
    return true;
}

bool Broker::Confirm(const std::string& rpId, uint32_t operation) {
    const std::string clean = SanitizeRpId(rpId);
    if (clean.empty() || (operation != 1 && operation != 2)) return false;
    Request request;
    request.kind = Kind::Confirm;
    request.text = clean;
    request.operation = operation;
    const auto reply = Exchange(request, kConfirmTimeout, true);
    return reply && reply->ok;
}

Authenticator Broker::Select(std::string& product) {
    Request request;
    request.kind = Kind::Select;
    const auto reply = Exchange(request, kSelectTimeout, true);
    if (!reply || !reply->ok) return Authenticator::None;
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_) return Authenticator::None;
    authorized_ = true;
    authenticator_ = reply->authenticator;
    product_ = reply->text;
    product = product_;
    return authenticator_;
}

Authenticator Broker::Authorized(std::string& product) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!authorized_ || closed_) return Authenticator::None;
    product = product_;
    return authenticator_;
}

void Broker::Forget() {
    bool release = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!authorized_) return;
        release = authenticator_ == Authenticator::UsbKey;
        authorized_ = false;
        authenticator_ = Authenticator::None;
        Wipe(product_);
    }
    if (release) Post(sessionId_, Kind::Release, 0);
}

void Broker::Unauthorize() {
    std::lock_guard<std::mutex> lock(mutex_);
    authorized_ = false;
    authenticator_ = Authenticator::None;
    Wipe(product_);
}

std::optional<std::vector<uint8_t>> Broker::Passkey(const std::vector<uint8_t>& command, const std::string& rpId) {
    if (command.size() < 2 || command.size() > kMaxPasskeyRequestBytes) return std::nullopt;
    Request request;
    request.kind = Kind::Passkey;
    request.text = SanitizeRpId(rpId);
    request.payload = command;
    // The phone may keep the request open for what is left of the remote request, within its own limit.
    request.timeoutMs = std::min<uint32_t>(RemainingMs(), kMaxPhoneRequestMs);
    auto reply = Exchange(request, kPasskeyTimeout, true);
    if (!reply || !reply->ok) return std::nullopt;
    return std::move(reply->payload);
}

std::optional<std::string> Broker::Pin(int32_t retries) {
    Request request;
    request.kind = Kind::Pin;
    request.retries = retries < -1 ? -1 : retries;
    auto reply = Exchange(request, kPinTimeout, true);
    if (!reply || !reply->ok || reply->text.empty()) {
        if (reply) Wipe(reply->text);
        return std::nullopt;
    }
    std::string pin = reply->text;
    Wipe(reply->text);
    return pin;
}

void Broker::Touch(bool waiting) { Post(sessionId_, Kind::Touch, waiting ? 1 : 0); }

bool Broker::WriteReport(const std::array<uint8_t, 64>& report) {
    Request request;
    request.kind = Kind::Write;
    request.report = report;
    const auto reply = Exchange(request, kWriteTimeout, false);
    return reply && reply->ok;
}

bool Broker::ReadReport(std::array<uint8_t, 64>& report, int timeoutMs) {
    Request request;
    request.kind = Kind::Read;
    request.timeoutMs = timeoutMs <= 0 ? kMaxReadMs : std::min<uint32_t>(uint32_t(timeoutMs), kMaxReadMs);
    const auto reply = Exchange(request, std::chrono::milliseconds(request.timeoutMs + kReadGraceMs), false);
    if (!reply || !reply->ok) return false;
    report = reply->report;
    return true;
}

std::shared_ptr<Broker> Attach(const void* context, uint64_t sessionId) {
    if (context == nullptr || sessionId == 0) return nullptr;
    auto broker = std::make_shared<Broker>(sessionId, ++g_lastGeneration);
    std::shared_ptr<Broker> previous;
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        auto& slot = g_brokers[context];
        previous = slot;
        slot = broker;
        // Creates the session on first attach; a reconnect keeps the existing watcher.
        g_sessions[sessionId];
    }
    Retire(previous);
    return broker;
}

std::shared_ptr<Broker> ForContext(const void* context) {
    std::lock_guard<std::mutex> lock(g_registryMutex);
    const auto found = g_brokers.find(context);
    return found == g_brokers.end() ? nullptr : found->second;
}

std::shared_ptr<Broker> ForGeneration(uint64_t generation) {
    std::lock_guard<std::mutex> lock(g_registryMutex);
    for (const auto& entry : g_brokers) {
        if (entry.second && entry.second->Generation() == generation) return entry.second;
    }
    return nullptr;
}

std::shared_ptr<Broker> ForSession(uint64_t sessionId) {
    std::lock_guard<std::mutex> lock(g_registryMutex);
    return OpenLocked(sessionId);
}

void Close(const void* context) { Retire(ForContext(context)); }

void Detach(const void* context) {
    std::shared_ptr<Broker> broker;
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        const auto found = g_brokers.find(context);
        if (found == g_brokers.end()) return;
        broker = found->second;
        g_brokers.erase(found);
    }
    if (!broker) return;
    Retire(broker);
    std::lock_guard<std::mutex> lock(g_registryMutex);
    PruneLocked(broker->SessionId());
}

bool Watch(uint64_t sessionId, std::function<void()> wake) {
    bool owed = false;
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        const auto broker = OpenLocked(sessionId);
        if (!broker) return false;
        Session& session = g_sessions[sessionId];
        session.wake = wake;
        owed = session.release || session.dismiss || session.touch || broker->HasUndelivered();
    }
    if (owed && wake) wake();
    return true;
}

void Unwatch(uint64_t sessionId) {
    std::lock_guard<std::mutex> lock(g_registryMutex);
    const auto found = g_sessions.find(sessionId);
    if (found == g_sessions.end()) return;
    // The watcher released its key and took its prompts down when it stopped.
    found->second = Session{};
    PruneLocked(sessionId);
}

bool Poll(uint64_t sessionId, Request& request) {
    std::shared_ptr<Broker> broker;
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        const auto found = g_sessions.find(sessionId);
        if (found != g_sessions.end()) {
            Session& session = found->second;
            // Release before any new Select, so a new authorization never races the old claim.
            if (session.release) {
                session.release = false;
                request = Notification(Kind::Release, 0, 0);
                return true;
            }
            if (session.dismiss) {
                request = Notification(Kind::Dismiss, 0, *session.dismiss);
                session.dismiss.reset();
                return true;
            }
        }
        broker = OpenLocked(sessionId);
    }
    if (broker && broker->Poll(request)) return true;
    std::lock_guard<std::mutex> lock(g_registryMutex);
    const auto found = g_sessions.find(sessionId);
    if (found == g_sessions.end() || !found->second.touch) return false;
    request = Notification(Kind::Touch, *found->second.touch, 0);
    found->second.touch.reset();
    return true;
}

bool Respond(uint64_t sessionId, uint32_t id, const Reply& reply) {
    const auto broker = ForSession(sessionId);
    return broker && broker->Respond(id, reply);
}

void Cancel(uint64_t sessionId) {
    if (const auto broker = ForSession(sessionId)) broker->Cancel();
}

void Released(uint64_t sessionId) {
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        const auto found = g_sessions.find(sessionId);
        if (found != g_sessions.end()) found->second.release = false;
    }
    if (const auto broker = ForSession(sessionId)) broker->Unauthorize();
}

} // namespace RdpSecurityKey
