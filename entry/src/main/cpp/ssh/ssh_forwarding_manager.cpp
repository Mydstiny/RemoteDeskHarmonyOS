#include "ssh_forwarding_manager.h"
#include "common/endpoint_address_policy.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <limits>

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

uint64_t currentTimeMs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count());
}

} // namespace

bool SshForwardingManager::isValidMode(SshForwardingMode mode) {
    return mode == SshForwardingMode::Local ||
           mode == SshForwardingMode::Remote ||
           mode == SshForwardingMode::Dynamic;
}

bool SshForwardingManager::isLoopbackHost(const std::string& host) {
    const auto parsed = remotedesk::endpoint::ParseHost(
        trim(host), remotedesk::endpoint::ParseMode::Persisted);
    if (!parsed.ok) {
        return false;
    }
    switch (parsed.endpoint.family()) {
        case remotedesk::endpoint::AddressFamily::Hostname:
            return parsed.endpoint.canonicalHost() == "localhost";
        case remotedesk::endpoint::AddressFamily::Ipv4:
            return parsed.endpoint.canonicalHost().compare(0, 4, "127.") == 0;
        case remotedesk::endpoint::AddressFamily::Ipv6:
            return parsed.endpoint.canonicalHost() == "::1";
    }
    return false;
}

bool SshForwardingManager::isValidPort(int port) {
    return port >= 1 && port <= 65535;
}

uint64_t SshForwardingManager::nowMs() {
    return currentTimeMs();
}

SshForwardingResult SshForwardingManager::validateAndNormalize(SshForwardingConfig& config) {
    if (config.schemaVersion == 0) {
        config.schemaVersion = 1;
    }
    config.id = trim(config.id);
    config.bindHost = trim(config.bindHost);
    config.targetHost = trim(config.targetHost);
    if (config.bindHost.empty()) {
        config.bindHost = kDefaultBindHost;
    }

    if (config.id.empty() || config.id.size() > 96U) {
        return SshForwardingResult::InvalidId;
    }
    if (!isValidMode(config.mode)) {
        return SshForwardingResult::InvalidMode;
    }
    if (config.bindHost.empty() || config.bindHost.size() > 255U) {
        return SshForwardingResult::InvalidBindHost;
    }
    if (config.bindHost == "[::]") {
        config.bindHost = "::";
    } else if (config.bindHost != "0.0.0.0" && config.bindHost != "::") {
        const auto parsed = remotedesk::endpoint::ParseHost(
            config.bindHost, remotedesk::endpoint::ParseMode::Persisted);
        if (!parsed.ok ||
            (config.mode == SshForwardingMode::Remote &&
             !parsed.endpoint.scope().empty())) {
            // Remote listeners are created by the SSH server. A local
            // interface name has no meaning in that namespace.
            return SshForwardingResult::InvalidBindHost;
        }
        config.bindHost = remotedesk::endpoint::TransportHost(parsed.endpoint);
    }
    if (!config.allowPublicBind && !isLoopbackHost(config.bindHost)) {
        return SshForwardingResult::PublicBindNotAllowed;
    }
    if (!isValidPort(config.bindPort)) {
        return SshForwardingResult::InvalidBindPort;
    }
    if (config.minBindPort == 0) { config.minBindPort = 1; }
    if (config.maxBindPort == 0) { config.maxBindPort = 65535; }
    if (config.minBindPort > config.maxBindPort ||
        config.bindPort < config.minBindPort || config.bindPort > config.maxBindPort) {
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
    if (config.targetHost.empty() || config.targetHost.size() > 255U) {
        return SshForwardingResult::InvalidTargetHost;
    }
    const auto target = remotedesk::endpoint::ParseHost(
        config.targetHost, remotedesk::endpoint::ParseMode::Persisted);
    if (!target.ok ||
        (config.mode != SshForwardingMode::Remote && !target.endpoint.scope().empty())) {
        // Local forwarding targets are resolved by the SSH server and do not
        // share this device's interface namespace. Remote-forward targets are
        // connected locally and may retain an interface scope.
        return SshForwardingResult::InvalidTargetHost;
    }
    config.targetHost = remotedesk::endpoint::TransportHost(target.endpoint);
    if (!isValidPort(config.targetPort)) {
        return SshForwardingResult::InvalidTargetPort;
    }
    return SshForwardingResult::Ok;
}

bool SshForwardingManager::normalizeRuntimeTargetHost(std::string& host) {
    if (host.empty() || host.size() > remotedesk::endpoint::kMaxInputLength) {
        return false;
    }
    const auto parsed = remotedesk::endpoint::ParseHost(
        host, remotedesk::endpoint::ParseMode::Runtime);
    if (!parsed.ok || !parsed.endpoint.scope().empty()) {
        // SOCKS5 does not carry an IPv6 scope identifier. A domain-form `%`
        // fallback would silently change a scoped literal into a DNS name.
        return false;
    }
    host = remotedesk::endpoint::TransportHost(parsed.endpoint);
    return host.size() <= 255U;
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
    if (existing != entries_.end() && existing->second.activeConnections != 0) {
        // A failed runtime can still have connections waiting for the owner
        // reactor to close them. Replacing the profile here would clear the
        // count and let stale callbacks release against a new configuration.
        return SshForwardingResult::Busy;
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
    entry.transferredBytes = 0;
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
    if (entry->second.config.expiresAtMs != 0 &&
        nowMs() >= entry->second.config.expiresAtMs) {
        entry->second.state = SshForwardingState::Failed;
        entry->second.lastError = static_cast<int>(SshForwardingResult::Expired);
        return SshForwardingResult::Expired;
    }
    if ((entry->second.state != SshForwardingState::Stopped &&
         entry->second.state != SshForwardingState::Failed) ||
        entry->second.activeConnections != 0) {
        return SshForwardingResult::InvalidState;
    }
    entry->second.state = SshForwardingState::Starting;
    entry->second.sessionGeneration = sessionGeneration;
    entry->second.lastError = 0;
    entry->second.transferredBytes = 0;
    entry->second.actualBindHost.clear();
    entry->second.actualBindPort = 0;
    entry->second.actualBindFamily = 0;
    return SshForwardingResult::Ok;
}

SshForwardingResult SshForwardingManager::markListening(const std::string& id,
                                                        uint64_t sessionGeneration,
                                                        const std::string& actualBindHost,
                                                        int actualBindPort,
                                                        int actualBindFamily) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (!generationMatches(entry->second, sessionGeneration)) {
        return SshForwardingResult::StaleSession;
    }
    if (entry->second.state == SshForwardingState::Listening) {
        return SshForwardingResult::Ok;
    }
    if (entry->second.state != SshForwardingState::Starting) {
        return SshForwardingResult::InvalidState;
    }
    entry->second.state = SshForwardingState::Listening;
    entry->second.actualBindHost = actualBindHost;
    entry->second.actualBindPort = actualBindPort;
    entry->second.actualBindFamily = actualBindFamily;
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
    entry->second.actualBindHost.clear();
    entry->second.actualBindPort = 0;
    entry->second.actualBindFamily = 0;
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
    const SshForwardingResult limits = checkRuntimeLimitsLocked(entry->second, sessionGeneration);
    if (limits != SshForwardingResult::Ok) {
        return limits;
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

SshForwardingResult SshForwardingManager::recordBytes(const std::string& id,
                                                      uint64_t sessionGeneration,
                                                      uint64_t bytes) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (!generationMatches(entry->second, sessionGeneration)) {
        return SshForwardingResult::StaleSession;
    }
    const SshForwardingResult limits = checkRuntimeLimitsLocked(entry->second, sessionGeneration);
    if (limits != SshForwardingResult::Ok) {
        return limits;
    }
    if (entry->second.state != SshForwardingState::Listening) {
        return SshForwardingResult::InvalidState;
    }
    if (entry->second.config.maxBytes != 0 &&
        bytes > entry->second.config.maxBytes - entry->second.transferredBytes) {
        entry->second.state = SshForwardingState::Failed;
        entry->second.lastError = static_cast<int>(SshForwardingResult::ByteLimit);
        return SshForwardingResult::ByteLimit;
    }
    if (bytes > std::numeric_limits<uint64_t>::max() - entry->second.transferredBytes) {
        entry->second.state = SshForwardingState::Failed;
        entry->second.lastError = static_cast<int>(SshForwardingResult::ByteLimit);
        return SshForwardingResult::ByteLimit;
    }
    entry->second.transferredBytes += bytes;
    return SshForwardingResult::Ok;
}

uint64_t SshForwardingManager::remainingBytes(const std::string& id,
                                              uint64_t sessionGeneration) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end() || !generationMatches(entry->second, sessionGeneration) ||
        entry->second.state != SshForwardingState::Listening) {
        return 0;
    }
    if (entry->second.config.expiresAtMs != 0 &&
        nowMs() >= entry->second.config.expiresAtMs) {
        return 0;
    }
    if (entry->second.config.maxBytes == 0) {
        return std::numeric_limits<uint64_t>::max();
    }
    if (entry->second.transferredBytes >= entry->second.config.maxBytes) {
        return 0;
    }
    return entry->second.config.maxBytes - entry->second.transferredBytes;
}

SshForwardingResult SshForwardingManager::checkRuntimeLimits(
    const std::string& id, uint64_t sessionGeneration) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) {
        return SshForwardingResult::NotFound;
    }
    if (!generationMatches(entry->second, sessionGeneration)) {
        return SshForwardingResult::StaleSession;
    }
    return checkRuntimeLimitsLocked(entry->second, sessionGeneration);
}

SshForwardingResult SshForwardingManager::checkRuntimeLimitsLocked(
    Entry& entry, uint64_t sessionGeneration) {
    if (!generationMatches(entry, sessionGeneration)) {
        return SshForwardingResult::StaleSession;
    }
    if (entry.state != SshForwardingState::Listening) {
        return SshForwardingResult::InvalidState;
    }
    if (entry.config.expiresAtMs != 0 && nowMs() >= entry.config.expiresAtMs) {
        entry.state = SshForwardingState::Failed;
        entry.lastError = static_cast<int>(SshForwardingResult::Expired);
        return SshForwardingResult::Expired;
    }
    if (entry.config.maxBytes != 0 && entry.transferredBytes >= entry.config.maxBytes) {
        entry.state = SshForwardingState::Failed;
        entry.lastError = static_cast<int>(SshForwardingResult::ByteLimit);
        return SshForwardingResult::ByteLimit;
    }
    return SshForwardingResult::Ok;
}

void SshForwardingManager::resetRuntimeAfterTransportClose() {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto& [id, entry] : entries_) {
        (void)id;
        entry.state = SshForwardingState::Stopped;
        entry.sessionGeneration = 0;
        entry.activeConnections = 0;
        entry.lastError = 0;
        entry.transferredBytes = 0;
        entry.actualBindHost.clear();
        entry.actualBindPort = 0;
        entry.actualBindFamily = 0;
    }
}

SshForwardingSnapshot SshForwardingManager::toSnapshot(const Entry& entry) {
    SshForwardingSnapshot snapshot;
    snapshot.config = entry.config;
    snapshot.state = entry.state;
    snapshot.sessionGeneration = entry.sessionGeneration;
    snapshot.activeConnections = entry.activeConnections;
    snapshot.lastError = entry.lastError;
    snapshot.transferredBytes = entry.transferredBytes;
    snapshot.expiresAtMs = entry.config.expiresAtMs;
    snapshot.actualBindHost = entry.actualBindHost;
    snapshot.actualBindPort = entry.actualBindPort;
    snapshot.actualBindFamily = entry.actualBindFamily;
    return snapshot;
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
