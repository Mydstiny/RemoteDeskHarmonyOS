#include "rdp_security_key_broker.h"

#include <algorithm>
#include <map>

namespace RdpSecurityKey {
namespace {
constexpr size_t kMaxProductLength = 120;
constexpr size_t kMaxCtapMessage = 7609;

void Wipe(std::string& value) {
    std::fill(value.begin(), value.end(), '\0');
    value.clear();
}

std::string SanitizeLabel(const std::string& value, size_t limit) {
    std::string clean;
    for (const char raw : value) {
        const auto c = static_cast<unsigned char>(raw);
        if (c < 0x20 || c == 0x7f) continue;
        clean.push_back(raw);
        if (clean.size() >= limit) break;
    }
    return clean;
}

std::mutex g_registryMutex;
std::map<const void*, std::shared_ptr<Broker>> g_brokers;
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

Broker::Broker(uint64_t sessionId) : sessionId_(sessionId) {}

Broker::~Broker() { Close(); }

void Broker::SetCancelled(std::unique_lock<std::mutex>&, bool cancelled) {
    if (cancelled_ == cancelled) return;
    cancelled_ = cancelled;
    if (cancelListener_) cancelListener_(cancelled);
}

void Broker::Wake(std::unique_lock<std::mutex>& lock) {
    auto wake = wake_;
    if (!wake) return;
    lock.unlock();
    wake();
    lock.lock();
}

bool Broker::Begin() {
    std::unique_lock<std::mutex> lock(mutex_);
    if (closed_) return false;
    SetCancelled(lock, false);
    return true;
}

void Broker::Cancel() {
    std::unique_lock<std::mutex> lock(mutex_);
    SetCancelled(lock, true);
    changed_.notify_all();
}

void Broker::Close() {
    std::unique_lock<std::mutex> lock(mutex_);
    if (closed_) return;
    closed_ = true;
    SetCancelled(lock, true);
    if (authorized_) {
        authorized_ = false;
        Request release;
        release.kind = Kind::Release;
        release_ = release;
    }
    Wipe(product_);
    changed_.notify_all();
    Wake(lock);
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

void Broker::SetWake(std::function<void()> wake) {
    std::unique_lock<std::mutex> lock(mutex_);
    wake_ = std::move(wake);
    if (wake_ && (pending_ || touch_ || release_)) Wake(lock);
}

std::optional<Reply> Broker::Exchange(Request request, std::chrono::milliseconds timeout, bool userFacing) {
    std::unique_lock<std::mutex> lock(mutex_);
    const auto stopped = [&]() { return closed_ || (userFacing && cancelled_); };
    if (stopped()) return std::nullopt;
    // A single channel worker drives the protocol, so this only waits out a request that is finishing.
    if (!changed_.wait_for(lock, timeout, [&]() { return stopped() || !pending_; }) || stopped()) {
        return std::nullopt;
    }
    if (++nextId_ == 0) ++nextId_;
    request.id = nextId_;
    pending_ = request;
    delivered_ = false;
    reply_.reset();
    Wake(lock);
    const bool answered = changed_.wait_for(lock, timeout, [&]() { return stopped() || reply_.has_value(); });
    std::optional<Reply> result;
    if (answered && reply_ && !stopped()) result = reply_;
    if (reply_) Wipe(reply_->text);
    pending_.reset();
    reply_.reset();
    delivered_ = false;
    changed_.notify_all();
    return result;
}

void Broker::Notify(Kind kind, uint32_t operation) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (closed_) return;
    Request notification;
    notification.kind = kind;
    notification.operation = operation;
    if (kind == Kind::Touch) touch_ = notification;
    else release_ = notification;
    Wake(lock);
}

bool Broker::Poll(Request& request) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pending_ && !delivered_) {
        request = *pending_;
        delivered_ = true;
        return true;
    }
    if (release_) {
        request = *release_;
        release_.reset();
        return true;
    }
    if (touch_) {
        request = *touch_;
        touch_.reset();
        return true;
    }
    return false;
}

bool Broker::Respond(uint32_t id, const Reply& reply) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_ || !pending_ || !delivered_ || reply_ || pending_->id != id) return false;
    Reply accepted = reply;
    switch (pending_->kind) {
        case Kind::Confirm:
        case Kind::Write:
            accepted.text.clear();
            break;
        case Kind::Select:
            accepted.text = SanitizeLabel(accepted.text, kMaxProductLength);
            break;
        case Kind::Pin:
            if (accepted.text.size() > kMaxPinBytes || accepted.text.find('\0') != std::string::npos) {
                accepted.ok = false;
                Wipe(accepted.text);
            }
            break;
        case Kind::Read:
            accepted.text.clear();
            // An initialization frame never declares more than a full CTAP HID message.
            if (accepted.ok && (accepted.report[4] & 0x80) != 0 &&
                (size_t(accepted.report[5]) << 8 | accepted.report[6]) > kMaxCtapMessage) {
                accepted.ok = false;
            }
            break;
        default:
            return false;
    }
    reply_ = accepted;
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

bool Broker::Select(std::string& product) {
    Request request;
    request.kind = Kind::Select;
    const auto reply = Exchange(request, kSelectTimeout, true);
    if (!reply || !reply->ok) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_) return false;
    authorized_ = true;
    product_ = reply->text;
    product = product_;
    return true;
}

bool Broker::Authorized(std::string& product) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!authorized_ || closed_) return false;
    product = product_;
    return true;
}

void Broker::Forget() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!authorized_) return;
        authorized_ = false;
        Wipe(product_);
    }
    Notify(Kind::Release, 0);
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

void Broker::Touch(bool waiting) { Notify(Kind::Touch, waiting ? 1 : 0); }

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
    const auto reply = Exchange(request, std::chrono::milliseconds(request.timeoutMs + 1500), false);
    if (!reply || !reply->ok) return false;
    report = reply->report;
    return true;
}

std::shared_ptr<Broker> Attach(const void* context, uint64_t sessionId) {
    if (context == nullptr || sessionId == 0) return nullptr;
    auto broker = std::make_shared<Broker>(sessionId);
    std::shared_ptr<Broker> previous;
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        auto& slot = g_brokers[context];
        previous = slot;
        slot = broker;
    }
    if (previous) previous->Close();
    return broker;
}

std::shared_ptr<Broker> ForContext(const void* context) {
    std::lock_guard<std::mutex> lock(g_registryMutex);
    const auto found = g_brokers.find(context);
    return found == g_brokers.end() ? nullptr : found->second;
}

std::shared_ptr<Broker> ForSession(uint64_t sessionId) {
    std::lock_guard<std::mutex> lock(g_registryMutex);
    // A reconnect attaches the new context before the old one is detached; the open broker wins.
    for (const auto& entry : g_brokers) {
        if (entry.second && entry.second->SessionId() == sessionId && !entry.second->Closed()) return entry.second;
    }
    return nullptr;
}

void Close(const void* context) {
    const auto broker = ForContext(context);
    if (broker) broker->Close();
}

void Detach(const void* context) {
    std::shared_ptr<Broker> broker;
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        const auto found = g_brokers.find(context);
        if (found == g_brokers.end()) return;
        broker = found->second;
        g_brokers.erase(found);
    }
    if (broker) broker->Close();
}

} // namespace RdpSecurityKey
