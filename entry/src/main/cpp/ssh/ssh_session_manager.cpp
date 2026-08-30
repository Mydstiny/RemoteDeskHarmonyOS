#include "ssh_session_manager.h"

#include <algorithm>
#include <chrono>
#include <map>

namespace {

bool isTerminal(SshSessionLifecycleState state) {
    return state == SshSessionLifecycleState::Closed;
}

} // namespace

uint64_t SshSessionManager::timestampMs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count());
}

bool SshSessionManager::validTransition(SshSessionLifecycleState from,
    SshSessionLifecycleState to) {
    if (from == to) {
        return true;
    }
    if (isTerminal(from)) {
        return false;
    }
    switch (from) {
        case SshSessionLifecycleState::Created:
            return to == SshSessionLifecycleState::Connecting ||
                to == SshSessionLifecycleState::Closing ||
                to == SshSessionLifecycleState::Failed;
        case SshSessionLifecycleState::Connecting:
            return to == SshSessionLifecycleState::Authenticating ||
                to == SshSessionLifecycleState::NetworkLost ||
                to == SshSessionLifecycleState::Failed ||
                to == SshSessionLifecycleState::Closing;
        case SshSessionLifecycleState::Authenticating:
            return to == SshSessionLifecycleState::Ready ||
                to == SshSessionLifecycleState::NeedsAuthentication ||
                to == SshSessionLifecycleState::NetworkLost ||
                to == SshSessionLifecycleState::Failed ||
                to == SshSessionLifecycleState::Closing;
        case SshSessionLifecycleState::Ready:
            return to == SshSessionLifecycleState::NetworkLost ||
                to == SshSessionLifecycleState::NeedsAuthentication ||
                to == SshSessionLifecycleState::Closing ||
                to == SshSessionLifecycleState::Failed;
        case SshSessionLifecycleState::NetworkLost:
            return to == SshSessionLifecycleState::ReconnectScheduled ||
                to == SshSessionLifecycleState::NeedsAuthentication ||
                to == SshSessionLifecycleState::Failed ||
                to == SshSessionLifecycleState::Closing;
        case SshSessionLifecycleState::ReconnectScheduled:
            return to == SshSessionLifecycleState::Reconnecting ||
                to == SshSessionLifecycleState::NeedsAuthentication ||
                to == SshSessionLifecycleState::Failed ||
                to == SshSessionLifecycleState::Closing;
        case SshSessionLifecycleState::Reconnecting:
            return to == SshSessionLifecycleState::Ready ||
                to == SshSessionLifecycleState::NeedsAuthentication ||
                to == SshSessionLifecycleState::NetworkLost ||
                to == SshSessionLifecycleState::Failed ||
                to == SshSessionLifecycleState::Closing;
        case SshSessionLifecycleState::NeedsAuthentication:
            return to == SshSessionLifecycleState::Authenticating ||
                to == SshSessionLifecycleState::Ready ||
                to == SshSessionLifecycleState::Failed ||
                to == SshSessionLifecycleState::Closing;
        case SshSessionLifecycleState::Failed:
            return to == SshSessionLifecycleState::ReconnectScheduled ||
                to == SshSessionLifecycleState::Connecting ||
                to == SshSessionLifecycleState::Closing;
        case SshSessionLifecycleState::Closing:
            return to == SshSessionLifecycleState::Closed ||
                to == SshSessionLifecycleState::Failed;
        case SshSessionLifecycleState::Closed:
            return false;
    }
    return false;
}

SshSessionManagerResult SshSessionManager::resolveLocked(
    const std::map<uint64_t, Entry>& entries,
    const SshSessionHandle& handle, const Entry*& out) {
    out = nullptr;
    if (!handle.valid()) {
        return SshSessionManagerResult::InvalidIdentity;
    }
    const auto it = entries.find(handle.sessionId);
    if (it == entries.end()) {
        return SshSessionManagerResult::NotFound;
    }
    if (it->second.context.generation != handle.generation ||
        it->second.context.channelId != handle.channelId) {
        return SshSessionManagerResult::StaleSession;
    }
    out = &it->second;
    return SshSessionManagerResult::Ok;
}

SshSessionManagerResult SshSessionManager::registerSession(
    const SshSessionHandle& handle, const std::string& host, int port,
    const std::shared_ptr<SshAdapter>& adapter,
    SshNetworkAvailabilityCallback networkCallback) {
    if (!handle.valid() || host.empty() || port <= 0 || port > 65535) {
        return SshSessionManagerResult::InvalidIdentity;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (entries_.size() >= kMaxSessions && entries_.find(handle.sessionId) == entries_.end()) {
        return SshSessionManagerResult::LimitReached;
    }
    if (entries_.find(handle.sessionId) != entries_.end()) {
        return SshSessionManagerResult::AlreadyExists;
    }
    Entry entry;
    entry.context.sessionId = handle.sessionId;
    entry.context.generation = handle.generation;
    entry.context.channelId = handle.channelId;
    entry.context.host = host;
    entry.context.port = port;
    entry.context.adapter = adapter;
    entry.context.networkCallback = std::move(networkCallback);
    entries_.emplace(handle.sessionId, std::move(entry));
    return SshSessionManagerResult::Ok;
}

SshSessionManagerResult SshSessionManager::closeSession(
    const SshSessionHandle& handle, bool remove) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = entries_.find(handle.sessionId);
    if (it == entries_.end()) {
        return SshSessionManagerResult::NotFound;
    }
    if (!handle.valid() || it->second.context.generation != handle.generation ||
        it->second.context.channelId != handle.channelId) {
        return SshSessionManagerResult::StaleSession;
    }
    it->second.context.state = SshSessionLifecycleState::Closed;
    it->second.context.eventSequence++;
    it->second.context.lastEventType = "closed";
    if (!remove) {
        return SshSessionManagerResult::Ok;
    }
    entries_.erase(it);
    return SshSessionManagerResult::Ok;
}

SshSessionManagerResult SshSessionManager::transition(
    const SshSessionHandle& handle, SshSessionLifecycleState state,
    const std::string& eventType, const std::string& payloadJson, uint8_t priority) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(handle.sessionId);
    if (it == entries_.end()) {
        return SshSessionManagerResult::NotFound;
    }
    if (!handle.valid() || it->second.context.generation != handle.generation ||
        it->second.context.channelId != handle.channelId) {
        return SshSessionManagerResult::StaleSession;
    }
    if (!validTransition(it->second.context.state, state)) {
        return SshSessionManagerResult::InvalidTransition;
    }
    it->second.context.state = state;
    it->second.context.eventSequence++;
    it->second.context.lastEventType = eventType;
    SshEventEnvelope event;
    event.sessionId = handle.sessionId;
    event.generation = handle.generation;
    event.channelId = handle.channelId;
    event.sequence = it->second.context.eventSequence;
    event.timestampMs = timestampMs();
    event.priority = priority;
    event.type = eventType;
    event.payloadJson = payloadJson.size() > 8192 ? payloadJson.substr(0, 8192) : payloadJson;
    it->second.events.push_back(std::move(event));
    if (it->second.events.size() > kMaxEventsPerSession) {
        it->second.events.erase(it->second.events.begin(),
            it->second.events.begin() + (it->second.events.size() - kMaxEventsPerSession));
    }
    return SshSessionManagerResult::Ok;
}

SshSessionManagerResult SshSessionManager::setBackgroundLimited(
    const SshSessionHandle& handle, bool limited, const std::string& reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(handle.sessionId);
    if (it == entries_.end()) {
        return SshSessionManagerResult::NotFound;
    }
    if (!handle.valid() || it->second.context.generation != handle.generation ||
        it->second.context.channelId != handle.channelId) {
        return SshSessionManagerResult::StaleSession;
    }
    it->second.context.backgroundLimited = limited;
    it->second.context.eventSequence++;
    it->second.context.lastEventType = limited ? "backgroundLimited" : "backgroundAvailable";
    SshEventEnvelope event;
    event.sessionId = handle.sessionId;
    event.generation = handle.generation;
    event.channelId = handle.channelId;
    event.sequence = it->second.context.eventSequence;
    event.timestampMs = timestampMs();
    event.type = it->second.context.lastEventType;
    event.payloadJson = reason.size() > 1024 ? reason.substr(0, 1024) : reason;
    it->second.events.push_back(std::move(event));
    return SshSessionManagerResult::Ok;
}

size_t SshSessionManager::notifyNetworkAvailability(bool available,
    uint64_t networkGeneration) {
    if (networkGeneration == 0) {
        return 0;
    }
    std::vector<SshNetworkAvailabilityCallback> callbacks;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        callbacks.reserve(entries_.size());
        for (const auto& item : entries_) {
            if (item.second.context.state == SshSessionLifecycleState::Closed) {
                continue;
            }
            if (item.second.context.networkCallback) {
                callbacks.push_back(item.second.context.networkCallback);
            }
        }
    }
    for (const SshNetworkAvailabilityCallback& callback : callbacks) {
        callback(available, networkGeneration);
    }
    return callbacks.size();
}

bool SshSessionManager::accepts(const SshSessionHandle& handle) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const Entry* entry = nullptr;
    return resolveLocked(entries_, handle, entry) == SshSessionManagerResult::Ok &&
        entry->context.state != SshSessionLifecycleState::Closed;
}

SshSessionSnapshot SshSessionManager::toSnapshot(const Entry& entry) {
    SshSessionSnapshot snapshot;
    snapshot.schemaVersion = entry.context.schemaVersion;
    snapshot.sessionId = entry.context.sessionId;
    snapshot.generation = entry.context.generation;
    snapshot.channelId = entry.context.channelId;
    snapshot.state = entry.context.state;
    snapshot.eventSequence = entry.context.eventSequence;
    snapshot.host = entry.context.host;
    snapshot.port = entry.context.port;
    snapshot.backgroundLimited = entry.context.backgroundLimited;
    snapshot.lastEventType = entry.context.lastEventType;
    return snapshot;
}

bool SshSessionManager::snapshot(const SshSessionHandle& handle,
    SshSessionSnapshot& out, SshSessionManagerResult* result) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const Entry* entry = nullptr;
    const SshSessionManagerResult resolved = resolveLocked(entries_, handle, entry);
    if (result != nullptr) {
        *result = resolved;
    }
    if (resolved != SshSessionManagerResult::Ok || entry == nullptr) {
        return false;
    }
    out = toSnapshot(*entry);
    return true;
}

std::vector<SshSessionSnapshot> SshSessionManager::snapshots() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<SshSessionSnapshot> result;
    result.reserve(entries_.size());
    for (const auto& item : entries_) {
        result.push_back(toSnapshot(item.second));
    }
    return result;
}

std::vector<SshEventEnvelope> SshSessionManager::events(
    const SshSessionHandle& handle, uint64_t afterSequence) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const Entry* entry = nullptr;
    if (resolveLocked(entries_, handle, entry) != SshSessionManagerResult::Ok || entry == nullptr) {
        return {};
    }
    std::vector<SshEventEnvelope> result;
    for (const SshEventEnvelope& event : entry->events) {
        if (event.sequence > afterSequence) {
            result.push_back(event);
        }
    }
    return result;
}

size_t SshSessionManager::size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return entries_.size();
}
