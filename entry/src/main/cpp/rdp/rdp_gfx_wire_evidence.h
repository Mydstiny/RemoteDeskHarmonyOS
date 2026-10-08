/**
 * rdp_gfx_wire_evidence.h - observed RDPGFX negotiation and wire-codec facts
 *
 * The graphics mode chosen before connect only describes what the client was
 * willing to advertise. These counters record what actually happened on the
 * wire: the capability sets sent to the server, the one capability set the
 * server confirmed, and the codec id carried by every surface command. They
 * contain no pixels, payload bytes, addresses or credentials.
 */

#ifndef RDP_GFX_WIRE_EVIDENCE_H
#define RDP_GFX_WIRE_EVIDENCE_H

#include <array>
#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>

/** Wire codec ids from [MS-RDPEGFX] 2.2.4.1 plus FreeRDP's AV1 extension. */
enum class RdpGfxWireCodecId : uint32_t {
    Uncompressed = 0x0000u,
    Av1 = 0x0001u,
    CaVideo = 0x0003u,
    ClearCodec = 0x0008u,
    CaProgressive = 0x0009u,
    Planar = 0x000Au,
    Avc420 = 0x000Bu,
    Alpha = 0x000Cu,
    CaProgressiveV2 = 0x000Du,
    Avc444 = 0x000Eu,
    Avc444v2 = 0x000Fu,
};

constexpr uint32_t kRdpGfxCodecSlots = 0x0010u;

/** Capability flags from [MS-RDPEGFX] 2.2.3. */
constexpr uint32_t kRdpGfxCapsFlagAvc420Enabled = 0x00000010u;
constexpr uint32_t kRdpGfxCapsFlagAvcDisabled = 0x00000020u;
constexpr uint32_t kRdpGfxCapsVersion8 = 0x00080004u;
constexpr uint32_t kRdpGfxCapsVersion81 = 0x00080105u;
constexpr uint32_t kRdpGfxCapsVersion10 = 0x000A0002u;
constexpr uint32_t kRdpGfxCapsVersionFreeRdp1 = 0x00010000u;

/** Stable, exportable codec name for one wire codec id. */
const char* RdpGfxWireCodecName(uint32_t codecId);

/** True when the capability set allows the server to send AVC (H.264) data. */
bool RdpGfxCapsAllowAvc(uint32_t version, uint32_t flags);

/** Stable, exportable capability version label ("8.0", "10.7", "unknown"). */
const char* RdpGfxCapsVersionName(uint32_t version);

struct RdpGfxRequestedSettings {
    bool applied = false;
    bool compiledGfx = false;
    bool compiledH264 = false;
    bool gfxConsumerAvailable = false;
    bool gfxResetSafe = false;
    bool h264PathSafe = false;
    bool fallbackConsumed = false;
    bool supportGraphicsPipeline = false;
    bool remoteFxCodec = false;
    bool gfxH264 = false;
};

struct RdpGfxWireEvidenceSnapshot {
    RdpGfxRequestedSettings requested;
    uint32_t capsAdvertisedCount = 0;
    uint32_t capsAdvertisedMaxVersion = 0;
    bool capsAdvertisedAvc = false;
    bool capsConfirmed = false;
    uint32_t capsConfirmedVersion = 0;
    uint32_t capsConfirmedFlags = 0;
    bool capsConfirmedAvc = false;
    uint64_t surfaceCommands = 0;
    uint64_t surfaceCommandBytes = 0;
    uint64_t avcSurfaceCommands = 0;
    /** Bit n is set when codec id n was observed in at least one surface command. */
    uint32_t codecMask = 0;
    /** Codec id with the most surface commands; kRdpGfxCodecSlots when none. */
    uint32_t dominantCodecId = kRdpGfxCodecSlots;
    uint64_t dominantCodecCommands = 0;
    uint64_t unknownCodecCommands = 0;
};

/** Lock-free per-session counters written from FreeRDP channel threads. */
class RdpGfxWireEvidence {
public:
    RdpGfxWireEvidence();

    /** Starts a new connection attempt; previous wire facts are discarded. */
    void reset(const RdpGfxRequestedSettings& requested);
    void recordCapsAdvertise(uint32_t count, uint32_t maxVersion, bool anyAvc);
    void recordCapsConfirm(uint32_t version, uint32_t flags);
    void recordSurfaceCommand(uint32_t codecId, uint32_t payloadBytes);

    RdpGfxWireEvidenceSnapshot snapshot() const;

private:
    mutable std::mutex settingsMutex_;
    RdpGfxRequestedSettings requested_;
    std::atomic<uint32_t> capsAdvertisedCount_ {0};
    std::atomic<uint32_t> capsAdvertisedMaxVersion_ {0};
    std::atomic<bool> capsAdvertisedAvc_ {false};
    std::atomic<bool> capsConfirmed_ {false};
    std::atomic<uint32_t> capsConfirmedVersion_ {0};
    std::atomic<uint32_t> capsConfirmedFlags_ {0};
    std::atomic<uint64_t> surfaceCommandBytes_ {0};
    std::atomic<uint64_t> unknownCodecCommands_ {0};
    std::array<std::atomic<uint64_t>, kRdpGfxCodecSlots> codecCommands_;
};

/**
 * One-shot GFX fallback scoped to the endpoint whose graphics pipeline failed.
 * A failure on one host must not silently downgrade an unrelated host; the
 * latch is consumed by the next connection to the same scope only.
 */
class RdpScopedGfxFallback {
public:
    static constexpr size_t kMaxScopes = 32;

    void mark(const std::string& scope, const char* reason);
    /** Returns true and the recorded reason when scope had a pending fallback. */
    bool consume(const std::string& scope, std::string* reason = nullptr);
    bool pending(const std::string& scope) const;
    size_t size() const;

private:
    struct Entry {
        std::string scope;
        std::string reason;
    };
    mutable std::mutex mutex_;
    std::deque<Entry> entries_;
};

/** Normalized in-memory scope key; never exported or logged. */
std::string RdpGfxFallbackScopeKey(const char* hostname, uint32_t port);

#endif // RDP_GFX_WIRE_EVIDENCE_H
