#include "moonlight/runtime/MoonlightProductStreamingRuntime.h"

#include "moonlight/media/MoonlightProductSessionMediaPort.h"
#include "moonlight/media/MoonlightStreamConfig.h"

#include <algorithm>
#include <chrono>
#include <mutex>
#include <optional>
#include <utility>

namespace remotedesk::moonlight {
namespace {

std::uint64_t monotonicMs() noexcept {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<
        std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}

bool sameLaunchKey(const MoonlightBridgeRequestKey& left,
                   const MoonlightBridgeRequestKey& right) noexcept {
    return left == right;
}

MoonlightStreamCapabilityEvidence evidence(
    MoonlightStreamCapabilitySource source, std::uint64_t generation,
    std::uint64_t now) {
    return {MoonlightStreamCapabilityStatus::Supported, source, "api23-product",
            generation, now + 60000U};
}

MoonlightStreamConfigResult resolveOffer(
    const MoonlightProductLaunchStage& stage, std::uint64_t now) noexcept {
    MoonlightRequestedStreamConfig requested;
    requested.requested.codecPreference = MoonlightStreamCodecPreference::H264;
    requested.requested.resolutionMode = MoonlightStreamResolutionMode::Custom;
    requested.requested.customWidth = static_cast<std::int32_t>(stage.configuration.width);
    requested.requested.customHeight = static_cast<std::int32_t>(stage.configuration.height);
    requested.requested.fps = static_cast<std::int32_t>(stage.configuration.refreshRate);
    requested.requested.bitrateKbps = 20000;
    requested.requested.hdr = false;
    requested.requested.yuv444 = false;
    requested.requested.latencyMode = MoonlightStreamLatencyMode::LowLatency;
    requested.requested.audioEnabled = true;
    requested.requested.audioLayout = MoonlightStreamAudioLayout::Stereo;
    requested.requested.playAudioOnHost = stage.configuration.playAudioOnHost;
    requested.requested.encryptionPolicy = MoonlightStreamEncryptionPolicy::Auto;
    requested.requested.meteredPolicy = MoonlightStreamMeteredPolicy::Allow;
    requested.d1Effective = requested.requested;

    const std::int32_t width = requested.requested.customWidth;
    const std::int32_t height = requested.requested.customHeight;
    const std::int32_t fps = requested.requested.fps;
    const MoonlightStreamCodecProfile h264 {
        MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
        MoonlightStreamChroma::Yuv420};
    MoonlightStreamCapabilitySnapshot capabilities;
    capabilities.host.evidence = evidence(
        MoonlightStreamCapabilitySource::Host, stage.key.generation, now);
    capabilities.host.recommendedMode = MoonlightStreamDimensions {width, height};
    capabilities.host.maxWidth = width;
    capabilities.host.maxHeight = height;
    capabilities.host.maxFps = std::max(1, fps);
    capabilities.host.maxEncoderBitrateKbps = 100000;
    capabilities.host.codecProfiles = {h264};
    capabilities.host.rec709Limited = true;
    capabilities.host.opusStereo = true;
    capabilities.host.encryptionStreams =
        MoonlightStreamEncryptAudio | MoonlightStreamEncryptVideo;

    capabilities.platform.evidence = evidence(
        MoonlightStreamCapabilitySource::PlatformProbe, stage.key.generation, now);
    capabilities.platform.maxWidth = width;
    capabilities.platform.maxHeight = height;
    capabilities.platform.maxFps = std::max(1, fps);
    capabilities.platform.maxDecodeBitrateKbps = 100000;
    capabilities.platform.maxThermalBitrateKbps = 100000;
    capabilities.platform.decoderProfiles = {h264};
    capabilities.platform.opusStereoOutput = true;
    capabilities.platform.commonCOpusMultistream = true;
    capabilities.platform.commonCEncryptionStreams =
        MoonlightStreamEncryptAudio | MoonlightStreamEncryptVideo;

    capabilities.network.evidence = evidence(
        MoonlightStreamCapabilitySource::NetworkProbe, stage.key.generation, now);
    capabilities.network.path = MoonlightStreamNetworkPath::Local;
    capabilities.network.addressFamily = stage.address.find(':') == std::string::npos
        ? MoonlightStreamAddressFamily::Ipv4 : MoonlightStreamAddressFamily::Ipv6;
    capabilities.network.vpnClassificationKnown = true;
    capabilities.network.nat64ClassificationKnown = true;
    capabilities.network.mtuReceiptAvailable = true;
    capabilities.network.safeVideoPacketSizeBytes = 1024;
    capabilities.network.metered = MoonlightStreamMeteredState::Unmetered;
    capabilities.network.maxBitrateKbps = 100000;

    capabilities.display.evidence = evidence(
        MoonlightStreamCapabilitySource::DisplayProbe, stage.key.generation, now);
    capabilities.display.maxWidth = width;
    capabilities.display.maxHeight = height;
    capabilities.display.maxFps = std::max(1, fps);
    capabilities.display.refreshRateX100 = std::max(1, fps) * 100;
    capabilities.display.rec709Limited = true;

    MoonlightStreamConfigIdentity identity;
    identity.ownerToken = stage.key.ownerToken;
    identity.sessionGeneration = stage.key.generation;
    identity.hostId = stage.hostId;
    identity.serverUuid = stage.serverUuid;
    identity.settingsRevision = stage.key.generation;
    identity.hostCapabilityGeneration = stage.key.generation;
    identity.platformProbeGeneration = stage.key.generation;
    identity.networkCapabilityGeneration = stage.key.generation;
    identity.displayCapabilityGeneration = stage.key.generation;
    return resolveMoonlightStreamConfig(requested, capabilities, identity, now);
}

const char* startCode(MoonlightCommonCStartStatus status) noexcept {
    switch (status) {
        case MoonlightCommonCStartStatus::Accepted: return "accepted";
        case MoonlightCommonCStartStatus::Busy: return "busy";
        case MoonlightCommonCStartStatus::RuntimeProofRequired: return "runtime_proof_required";
        case MoonlightCommonCStartStatus::InvalidRequest: return "invalid_request";
        case MoonlightCommonCStartStatus::InternalFailure: return "internal_failure";
    }
    return "internal_failure";
}

} // namespace

struct MoonlightProductStreamingRuntime::State final {
    std::mutex mutex;
    std::optional<MoonlightProductLaunchStage> staged;
    MoonlightBridgeRequestKey activeLaunchKey {};
    MoonlightSessionKey activeSessionKey {};
};

MoonlightProductStreamingRuntime& MoonlightProductStreamingRuntime::process() noexcept {
    static MoonlightProductStreamingRuntime runtime;
    return runtime;
}

MoonlightProductStreamingRuntime::State&
MoonlightProductStreamingRuntime::state() noexcept {
    static State value;
    return value;
}

bool MoonlightProductStreamingRuntime::stageLaunch(
    MoonlightProductLaunchStage stage) noexcept {
    if (!stage.key.valid() || stage.hostId.empty() || stage.serverUuid.empty() ||
        stage.address.empty() || stage.appId == 0U || stage.rtspSessionUrl.empty() ||
        stage.expiresAtMonotonicMs <= monotonicMs()) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return false;
    }
    try {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeSessionKey.valid()) {
            std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
            return false;
        }
        if (value.staged.has_value()) {
            std::fill(value.staged->remoteInputKey.begin(),
                      value.staged->remoteInputKey.end(), 0U);
        }
        value.staged = std::move(stage);
        return true;
    } catch (...) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return false;
    }
}

MoonlightProductStreamStartResult MoonlightProductStreamingRuntime::start(
    MoonlightProductStreamStartRequest request) noexcept {
    MoonlightProductLaunchStage stage;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeSessionKey.valid()) {
            return {false, "busy", {}};
        }
        if (!value.staged.has_value() ||
            !sameLaunchKey(value.staged->key, request.launchKey) ||
            value.staged->hostId != request.hostId ||
            value.staged->serverUuid != request.serverUuid ||
            value.staged->appId != request.appId ||
            value.staged->expiresAtMonotonicMs <= monotonicMs()) {
            return {false, "launch_lease_missing", {}};
        }
        stage = std::move(*value.staged);
        value.staged.reset();
    }
    if (request.rendererHandle <= 0 || request.surfaceWidth <= 0 ||
        request.surfaceHeight <= 0) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return {false, "invalid_surface", {}};
    }
    const auto now = monotonicMs();
    auto streamConfig = resolveOffer(stage, now);
    if (!streamConfig.ready()) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return {false, "stream_config_rejected", {}};
    }
    auto media = MoonlightProductSessionMediaPort::create(
        request.rendererHandle,
        static_cast<std::int32_t>(stage.configuration.width),
        static_cast<std::int32_t>(stage.configuration.height));
    if (media == nullptr) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return {false, "media_unavailable", {}};
    }
    MoonlightCommonCRequest common;
    common.sessionId = stage.key.requestId;
    common.generation = stage.key.generation;
    common.accountOwnerToken = stage.key.ownerToken;
    common.streamConfig = std::move(streamConfig);
    common.server.address = stage.address;
    common.server.appVersion = stage.serverInfo.appVersion;
    common.server.gfeVersion = stage.serverInfo.gfeVersion;
    common.server.authenticated = true;
    common.server.hostCapabilityGeneration = stage.key.generation;
    common.server.codecProfiles = {{MoonlightStreamCodec::H264,
        MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420}};
    common.launchLease = MoonlightRtspLaunchLease(
        stage.remoteInputKey, stage.remoteInputKeyId,
        std::move(stage.rtspSessionUrl), stage.key.ownerToken,
        stage.key.generation, stage.hostId, stage.serverUuid,
        stage.key.generation, stage.key.generation);
    std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
    common.deadlines.overallMonotonicMs = now + 30000U;
    common.deadlines.stageMonotonicMs.fill(now + 15000U);
    const auto started = MoonlightCommonCAdapter::process().startWithMedia(
        std::move(common), std::move(media));
    if (started.status != MoonlightCommonCStartStatus::Accepted) {
        return {false, startCode(started.status), {}};
    }
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        value.activeLaunchKey = request.launchKey;
        value.activeSessionKey = started.key;
    }
    return {true, "accepted", started.key};
}

MoonlightProductStreamSnapshot MoonlightProductStreamingRuntime::snapshot(
    const MoonlightBridgeRequestKey& launchKey) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey || !value.activeSessionKey.valid()) {
            return {};
        }
        key = value.activeSessionKey;
    }
    const auto source = MoonlightCommonCAdapter::process().snapshot(key);
    MoonlightProductStreamSnapshot result;
    result.matched = source.matched;
    result.key = source.key;
    result.code = source.terminal ? "terminal" : source.firstFrameReady
        ? "first_frame" : source.transportReady ? "transport_ready" : "starting";
    result.transportReady = source.transportReady;
    result.firstFrameReady = source.firstFrameReady;
    result.terminal = source.terminal;
    result.lastSequence = source.lastSequence;
    if (source.terminal) {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey == launchKey && value.activeSessionKey == key) {
            value.activeLaunchKey = {};
            value.activeSessionKey = {};
        }
    }
    return result;
}

bool MoonlightProductStreamingRuntime::requestStop(
    const MoonlightBridgeRequestKey& launchKey) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    const auto result = MoonlightCommonCAdapter::process().requestStop(key);
    return result == MoonlightStopStatus::StopRequested ||
        result == MoonlightStopStatus::AlreadyTerminal;
}

bool MoonlightProductStreamingRuntime::stop(
    const MoonlightBridgeRequestKey& launchKey) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    const auto result = MoonlightCommonCAdapter::process().stop(
        key, std::chrono::seconds(5));
    const bool stopped = result == MoonlightStopStatus::Stopped ||
        result == MoonlightStopStatus::AlreadyTerminal;
    if (stopped) {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey == launchKey && value.activeSessionKey == key) {
            value.activeLaunchKey = {};
            value.activeSessionKey = {};
        }
    }
    return stopped;
}

void MoonlightProductStreamingRuntime::shutdown() noexcept {
    MoonlightBridgeRequestKey launchKey;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.staged.has_value()) {
            std::fill(value.staged->remoteInputKey.begin(),
                      value.staged->remoteInputKey.end(), 0U);
            value.staged.reset();
        }
        launchKey = value.activeLaunchKey;
    }
    if (launchKey.valid()) { (void)stop(launchKey); }
}

} // namespace remotedesk::moonlight
