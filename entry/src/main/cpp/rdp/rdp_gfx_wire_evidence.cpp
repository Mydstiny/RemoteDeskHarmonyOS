#include "rdp/rdp_gfx_wire_evidence.h"

#include <algorithm>
#include <cctype>

const char* RdpGfxWireCodecName(uint32_t codecId) {
    switch (static_cast<RdpGfxWireCodecId>(codecId)) {
        case RdpGfxWireCodecId::Uncompressed: return "uncompressed";
        case RdpGfxWireCodecId::Av1: return "av1";
        case RdpGfxWireCodecId::CaVideo: return "remotefx";
        case RdpGfxWireCodecId::ClearCodec: return "clearcodec";
        case RdpGfxWireCodecId::CaProgressive: return "progressive";
        case RdpGfxWireCodecId::Planar: return "planar";
        case RdpGfxWireCodecId::Avc420: return "avc420";
        case RdpGfxWireCodecId::Alpha: return "alpha";
        case RdpGfxWireCodecId::CaProgressiveV2: return "progressive_v2";
        case RdpGfxWireCodecId::Avc444: return "avc444";
        case RdpGfxWireCodecId::Avc444v2: return "avc444v2";
        default: return "unknown";
    }
}

bool RdpGfxCapsAllowAvc(uint32_t version, uint32_t flags) {
    if (version == kRdpGfxCapsVersion8) {
        return false;
    }
    if (version == kRdpGfxCapsVersion81) {
        return (flags & kRdpGfxCapsFlagAvc420Enabled) != 0;
    }
    if (version >= kRdpGfxCapsVersion10 || version == kRdpGfxCapsVersionFreeRdp1) {
        return (flags & kRdpGfxCapsFlagAvcDisabled) == 0;
    }
    return false;
}

const char* RdpGfxCapsVersionName(uint32_t version) {
    switch (version) {
        case 0x00080004u: return "8.0";
        case 0x00080105u: return "8.1";
        case 0x000A0002u: return "10.0";
        case 0x000A0100u: return "10.1";
        case 0x000A0200u: return "10.2";
        case 0x000A0301u: return "10.3";
        case 0x000A0400u: return "10.4";
        case 0x000A0502u: return "10.5";
        case 0x000A0600u: return "10.6";
        case 0x000A0601u: return "10.6-err";
        case 0x000A0701u: return "10.7";
        case 0x000B0101u: return "11.1";
        case 0x000B0200u: return "11.2";
        case 0x000B0300u: return "11.3";
        case kRdpGfxCapsVersionFreeRdp1: return "freerdp-1";
        default: return "unknown";
    }
}

RdpGfxWireEvidence::RdpGfxWireEvidence() {
    for (auto& slot : codecCommands_) {
        slot.store(0, std::memory_order_relaxed);
    }
}

void RdpGfxWireEvidence::reset(const RdpGfxRequestedSettings& requested) {
    {
        std::lock_guard<std::mutex> lock(settingsMutex_);
        requested_ = requested;
    }
    capsAdvertisedCount_.store(0, std::memory_order_relaxed);
    capsAdvertisedMaxVersion_.store(0, std::memory_order_relaxed);
    capsAdvertisedAvc_.store(false, std::memory_order_relaxed);
    capsConfirmedVersion_.store(0, std::memory_order_relaxed);
    capsConfirmedFlags_.store(0, std::memory_order_relaxed);
    surfaceCommandBytes_.store(0, std::memory_order_relaxed);
    unknownCodecCommands_.store(0, std::memory_order_relaxed);
    for (auto& slot : codecCommands_) {
        slot.store(0, std::memory_order_relaxed);
    }
    capsConfirmed_.store(false, std::memory_order_release);
}

void RdpGfxWireEvidence::recordCapsAdvertise(uint32_t count, uint32_t maxVersion, bool anyAvc) {
    capsAdvertisedCount_.store(count, std::memory_order_relaxed);
    capsAdvertisedMaxVersion_.store(maxVersion, std::memory_order_relaxed);
    capsAdvertisedAvc_.store(anyAvc, std::memory_order_release);
}

void RdpGfxWireEvidence::recordCapsConfirm(uint32_t version, uint32_t flags) {
    capsConfirmedVersion_.store(version, std::memory_order_relaxed);
    capsConfirmedFlags_.store(flags, std::memory_order_relaxed);
    capsConfirmed_.store(true, std::memory_order_release);
}

void RdpGfxWireEvidence::recordSurfaceCommand(uint32_t codecId, uint32_t payloadBytes) {
    surfaceCommandBytes_.fetch_add(payloadBytes, std::memory_order_relaxed);
    if (codecId < kRdpGfxCodecSlots) {
        codecCommands_[codecId].fetch_add(1, std::memory_order_relaxed);
    } else {
        unknownCodecCommands_.fetch_add(1, std::memory_order_relaxed);
    }
}

RdpGfxWireEvidenceSnapshot RdpGfxWireEvidence::snapshot() const {
    RdpGfxWireEvidenceSnapshot result;
    {
        std::lock_guard<std::mutex> lock(settingsMutex_);
        result.requested = requested_;
    }
    result.capsConfirmed = capsConfirmed_.load(std::memory_order_acquire);
    result.capsConfirmedVersion = capsConfirmedVersion_.load(std::memory_order_relaxed);
    result.capsConfirmedFlags = capsConfirmedFlags_.load(std::memory_order_relaxed);
    result.capsConfirmedAvc = result.capsConfirmed &&
        RdpGfxCapsAllowAvc(result.capsConfirmedVersion, result.capsConfirmedFlags);
    result.capsAdvertisedAvc = capsAdvertisedAvc_.load(std::memory_order_acquire);
    result.capsAdvertisedCount = capsAdvertisedCount_.load(std::memory_order_relaxed);
    result.capsAdvertisedMaxVersion = capsAdvertisedMaxVersion_.load(std::memory_order_relaxed);
    result.surfaceCommandBytes = surfaceCommandBytes_.load(std::memory_order_relaxed);
    result.unknownCodecCommands = unknownCodecCommands_.load(std::memory_order_relaxed);
    result.surfaceCommands = result.unknownCodecCommands;
    for (uint32_t codec = 0; codec < kRdpGfxCodecSlots; ++codec) {
        const uint64_t count = codecCommands_[codec].load(std::memory_order_relaxed);
        if (count == 0) {
            continue;
        }
        result.surfaceCommands += count;
        result.codecMask |= (1u << codec);
        if (codec == static_cast<uint32_t>(RdpGfxWireCodecId::Avc420) ||
            codec == static_cast<uint32_t>(RdpGfxWireCodecId::Avc444) ||
            codec == static_cast<uint32_t>(RdpGfxWireCodecId::Avc444v2)) {
            result.avcSurfaceCommands += count;
        }
        if (count > result.dominantCodecCommands) {
            result.dominantCodecCommands = count;
            result.dominantCodecId = codec;
        }
    }
    return result;
}

void RdpScopedGfxFallback::mark(const std::string& scope, const char* reason) {
    if (scope.empty()) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.erase(std::remove_if(entries_.begin(), entries_.end(),
        [&scope](const Entry& entry) { return entry.scope == scope; }), entries_.end());
    entries_.push_back({scope, reason != nullptr ? reason : "unknown"});
    while (entries_.size() > kMaxScopes) {
        entries_.pop_front();
    }
}

bool RdpScopedGfxFallback::consume(const std::string& scope, std::string* reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto it = entries_.begin(); it != entries_.end(); ++it) {
        if (it->scope == scope) {
            if (reason != nullptr) {
                *reason = it->reason;
            }
            entries_.erase(it);
            return true;
        }
    }
    return false;
}

bool RdpScopedGfxFallback::pending(const std::string& scope) const {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const Entry& entry : entries_) {
        if (entry.scope == scope) {
            return true;
        }
    }
    return false;
}

size_t RdpScopedGfxFallback::size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return entries_.size();
}

std::string RdpGfxFallbackScopeKey(const char* hostname, uint32_t port) {
    std::string key = hostname != nullptr ? hostname : "";
    std::transform(key.begin(), key.end(), key.begin(),
        [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
    if (key.empty()) {
        return std::string();
    }
    return key + "#" + std::to_string(port);
}
