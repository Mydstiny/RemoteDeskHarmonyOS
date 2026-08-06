#include "ssh_forwarding_manager.h"

#include <algorithm>
#include <cctype>

namespace {

std::string trim(const std::string& value) {
    size_t begin = 0;
    while (begin < value.size() && std::isspace(static_cast<unsigned char>(value[begin]))) {
        ++begin;
    }
    size_t end = value.size();
    while (end > begin && std::isspace(static_cast<unsigned char>(value[end - 1]))) {
        --end;
    }
    return value.substr(begin, end - begin);
}

} // namespace

bool SshForwardingManager::isValidMode(SshForwardingMode mode) {
    return mode == SshForwardingMode::Local ||
           mode == SshForwardingMode::Remote ||
           mode == SshForwardingMode::Dynamic;
}

bool SshForwardingManager::isLoopbackHost(const std::string& host) {
    const std::string normalized = trim(host);
    if (normalized == "localhost" || normalized == "::1" || normalized == "[::1]") {
        return true;
    }
    if (normalized.size() >= 4 && normalized.compare(0, 4, "127.") == 0) {
        return true;
    }
    return false;
}

std::string SshForwardingManager::trimAndBound(const std::string& value,
                                               size_t maxLength,
                                               const std::string& fallback) {
    const std::string normalized = trim(value);
    if (normalized.empty()) {
        return fallback;
    }
    return normalized.substr(0, maxLength);
}

bool SshForwardingManager::isValidPort(int port) {
    return port >= 1 && port <= 65535;
}

SshForwardingResult SshForwardingManager::validateAndNormalize(SshForwardingConfig& config) {
    config.id = trimAndBound(config.id, 96);
    config.bindHost = trimAndBound(config.bindHost, 255, kDefaultBindHost);
    config.targetHost = trimAndBound(config.targetHost, 255);

    if (config.id.empty()) {
        return SshForwardingResult::InvalidId;
    }
    if (!isValidMode(config.mode)) {
        return SshForwardingResult::InvalidMode;
    }
    if (config.bindHost.empty() || config.bindHost.size() > 255) {
        return SshForwardingResult::InvalidBindHost;
    }
    if (!config.allowPublicBind && !isLoopbackHost(config.bindHost)) {
        return SshForwardingResult::PublicBindNotAllowed;
    }
    if (!isValidPort(config.bindPort)) {
        return SshForwardingResult::InvalidBindPort;
    }
    if (config.maxConnections == 0 || config.maxConnections > kMaxConnections) {
        return SshForwardingResult::InvalidConnectionLimit;
    }
    if (config.mode == SshForwardingMode::Dynamic) {
        if (!config.targetHost.empty() || config.targetPort != 0) {
            return SshForwardingResult::DynamicTargetSet;
        }
        return SshForwardingResult::Ok;
    }
    if (config.targetHost.empty() || config.targetHost.size() > 255) {
        return SshForwardingResult::InvalidTargetHost;
    }
    if (!isValidPort(config.targetPort)) {
        return SshForwardingResult::InvalidTargetPort;
    }
    return SshForwardingResult::Ok;
}

SshForwardingResult SshForwardingManager::upsert(const SshForwardingConfig& config) {
    SshForwardingConfig normalized = config;
    const SshForwardingResult validation = validateAndNormalize(normalized);
    if (validation != SshForwardingResult::Ok) {
        return validation;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    const auto existing = entries_.find(normalized.id);
    if (existing == entries_.end() && entries_.size() >= kMaxProfiles) {
        return SshForwardingResult::ProfileLimit;
    }
    if (existing != entries_.end() &&
        existing->second.state != SshForwardingState::Stopped &&
        existing->second.state != SshForwardingState::Failed) {
        return SshForwardingResult::Busy;
    }

    Entry& entry = entries_[normalized.id];
    entry.config = normalized;
    entry.state = SshForwardingState::Stopped;
    entry.sessionGeneration = 0;
    entry.activeConnections = 0;
    entry.lastError = 0;
    return SshForwardingResult::Ok;
}

SshForwardingResult SshForwardingManager::remove(const std::string& id) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (entry->second.state != SshForwardingState::Stopped ||
        entry->second.activeConnections != 0) {
        return SshForwardingResult::Busy;
    }
    entries_.erase(entry);
    return SshForwardingResult::Ok;
}

SshForwardingResult SshForwardingManager::start(const std::string& id,
                                                uint64_t sessionGeneration) {
    if (sessionGeneration == 0) {
        return SshForwardingResult::MissingGeneration;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (!entry->second.config.enabled) {
        return SshForwardingResult::Disabled;
    }
    if ((entry->second.state != SshForwardingState::Stopped &&
         entry->second.state != SshForwardingState::Failed) ||
        entry->second.activeConnections != 0) {
        return SshForwardingResult::InvalidState;
    }
    entry->second.state = SshForwardingState::Starting;
    entry->second.sessionGeneration = sessionGeneration;
    entry->second.lastError = 0;
    return SshForwardingResult::Ok;
}

SshForwardingResult SshForwardingManager::markListening(const std::string& id,
                                                        uint64_t sessionGeneration) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (!generationMatches(entry->second, sessionGeneration)) {
        return SshForwardingResult::StaleSession;
    }
    if (entry->second.state != SshForwardingState::Starting) {
        return SshForwardingResult::InvalidState;
    }
    entry->second.state = SshForwardingState::Listening;
    return SshForwardingResult::Ok;
}

SshForwardingResult SshForwardingManager::fail(const std::string& id,
                                               uint64_t sessionGeneration,
                                               int error) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (!generationMatches(entry->second, sessionGeneration)) {
        return SshForwardingResult::StaleSession;
    }
    if (entry->second.state == SshForwardingState::Stopped) {
        return SshForwardingResult::InvalidState;
    }
    entry->second.state = SshForwardingState::Failed;
    entry->second.lastError = error;
    return SshForwardingResult::Ok;
}

SshForwardingResult SshForwardingManager::requestStop(const std::string& id,
                                                      uint64_t sessionGeneration) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (entry->second.state == SshForwardingState::Stopped) {
        return SshForwardingResult::Ok;
    }
    if (!generationMatches(entry->second, sessionGeneration)) {
        return SshForwardingResult::StaleSession;
    }
    entry->second.state = SshForwardingState::Stopping;
    return SshForwardingResult::Ok;
}

SshForwardingResult SshForwardingManager::completeStop(const std::string& id) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (entry->second.activeConnections != 0) {
        return SshForwardingResult::Busy;
    }
    if (entry->second.state != SshForwardingState::Stopping &&
        entry->second.state != SshForwardingState::Failed) {
        return SshForwardingResult::InvalidState;
    }
    entry->second.state = SshForwardingState::Stopped;
    entry->second.sessionGeneration = 0;
    entry->second.lastError = 0;
    return SshForwardingResult::Ok;
}

SshForwardingResult SshForwardingManager::acquireConnection(
    const std::string& id, uint64_t sessionGeneration) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (!generationMatches(entry->second, sessionGeneration)) {
        return SshForwardingResult::StaleSession;
    }
    if (entry->second.state != SshForwardingState::Listening) {
        return SshForwardingResult::InvalidState;
    }
    if (entry->second.activeConnections >= entry->second.config.maxConnections) {
        return SshForwardingResult::ConnectionLimit;
    }
    ++entry->second.activeConnections;
    return SshForwardingResult::Ok;
}

SshForwardingResult SshForwardingManager::releaseConnection(
    const std::string& id, uint64_t sessionGeneration) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (!generationMatches(entry->second, sessionGeneration)) {
        return SshForwardingResult::StaleSession;
    }
    if (entry->second.activeConnections == 0) {
        return SshForwardingResult::InvalidState;
    }
    --entry->second.activeConnections;
    return SshForwardingResult::Ok;
}

SshForwardingSnapshot SshForwardingManager::toSnapshot(const Entry& entry) {
    return {entry.config, entry.state, entry.sessionGeneration,
            entry.activeConnections, entry.lastError};
}

bool SshForwardingManager::generationMatches(const Entry& entry,
                                             uint64_t sessionGeneration) {
    return sessionGeneration != 0 && entry.sessionGeneration == sessionGeneration;
}

std::vector<SshForwardingSnapshot> SshForwardingManager::snapshots() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<SshForwardingSnapshot> result;
    result.reserve(entries_.size());
    for (const auto& [id, entry] : entries_) {
        (void)id;
        result.push_back(toSnapshot(entry));
    }
    return result;
}

bool SshForwardingManager::snapshot(const std::string& id,
                                    SshForwardingSnapshot& out) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return false;
    }
    out = toSnapshot(entry->second);
    return true;
}

size_t SshForwardingManager::size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return entries_.size();
}
