#ifndef REMOTEDESK_MOONLIGHT_PRODUCT_STREAMING_RUNTIME_H
#define REMOTEDESK_MOONLIGHT_PRODUCT_STREAMING_RUNTIME_H

#include "moonlight/bridge/MoonlightNativeBridge.h"
#include "moonlight/core/MoonlightHostApi.h"
#include "moonlight/media/MoonlightCommonCAdapter.h"
#include "moonlight/input/MoonlightProductInputRuntime.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace remotedesk::moonlight {

struct MoonlightProductLaunchStage final {
    MoonlightBridgeRequestKey key {};
    std::string hostId;
    std::string serverUuid;
    std::string address;
    std::uint32_t appId = 0U;
    MoonlightBridgeLaunchConfiguration configuration {};
    MoonlightServerInfo serverInfo {};
    std::array<std::uint8_t, 16U> remoteInputKey {};
    std::int32_t remoteInputKeyId = 0;
    std::string rtspSessionUrl;
    std::uint64_t expiresAtMonotonicMs = 0U;
};

struct MoonlightProductStreamStartRequest final {
    MoonlightBridgeRequestKey launchKey {};
    std::string hostId;
    std::string serverUuid;
    std::uint32_t appId = 0U;
    std::int64_t rendererHandle = 0;
    std::int32_t surfaceWidth = 0;
    std::int32_t surfaceHeight = 0;
    // Native product policy, not a measured path-capability ceiling.
    std::int32_t configuredBitrateKbps = 20000;
    MoonlightStreamCodec codec = MoonlightStreamCodec::H264;
    bool hdr = false;
    bool yuv444 = false;
    MoonlightStreamLatencyMode latencyMode = MoonlightStreamLatencyMode::LowLatency;
    bool audioEnabled = true;
    MoonlightStreamAudioLayout audioLayout = MoonlightStreamAudioLayout::Stereo;
    bool playAudioOnHost = false;
    MoonlightStreamEncryptionPolicy encryptionPolicy =
        MoonlightStreamEncryptionPolicy::Auto;
};

constexpr std::uint32_t kMoonlightProductStereoAudioInfo = 196610U;

constexpr bool moonlightProductAudioContractAllows(
    bool audioEnabled, MoonlightStreamAudioLayout layout,
    std::uint32_t surroundAudioInfo = kMoonlightProductStereoAudioInfo) noexcept {
    // Product decode/playback and the disabled-audio discard lane currently
    // negotiate the common-c stereo shape only.
    return surroundAudioInfo == kMoonlightProductStereoAudioInfo &&
        (!audioEnabled || layout == MoonlightStreamAudioLayout::Stereo);
}

constexpr bool moonlightProductStreamingPolicyAllows(
    MoonlightStreamLatencyMode latencyMode,
    MoonlightStreamEncryptionPolicy encryptionPolicy) noexcept {
    // The current product lane has one measured queueing profile and common-c
    // does not expose proof that required A/V encryption was negotiated.
    return latencyMode == MoonlightStreamLatencyMode::LowLatency &&
        encryptionPolicy != MoonlightStreamEncryptionPolicy::Required;
}

struct MoonlightProductStreamStartResult final {
    bool accepted = false;
    std::string code = "invalid_request";
    MoonlightSessionKey key {};
};

struct MoonlightProductStreamSnapshot final {
    bool matched = false;
    MoonlightSessionKey key {};
    std::string code = "not_active";
    bool transportReady = false;
    bool videoReady = false;
    bool audioReady = false;
    bool inputReady = false;
    bool controllerReady = false;
    bool physicalControllerReady = false;
    bool firstFrameReady = false;
    bool terminal = false;
    std::uint64_t lastSequence = 0U;
};

class MoonlightProductStreamingRuntime final {
public:
    static MoonlightProductStreamingRuntime& process() noexcept;

    // Reserve the process-wide Moonlight streaming slot before dispatching a
    // remote launch/resume mutation. This prevents a second host mutation from
    // succeeding only to discover afterwards that its local launch lease
    // cannot be represented.
    bool reserveLaunch(const MoonlightBridgeRequestKey& launchKey) noexcept;
    bool releaseLaunchReservation(
        const MoonlightBridgeRequestKey& launchKey) noexcept;
    bool stageLaunch(MoonlightProductLaunchStage stage) noexcept;
    MoonlightProductStreamStartResult start(
        MoonlightProductStreamStartRequest request) noexcept;
    MoonlightProductStreamSnapshot snapshot(
        const MoonlightBridgeRequestKey& launchKey) noexcept;
    std::size_t cancelOwner(std::uint64_t ownerToken) noexcept;
    bool requestStop(const MoonlightBridgeRequestKey& launchKey) noexcept;
    bool stop(const MoonlightBridgeRequestKey& launchKey) noexcept;
    bool sendKey(const MoonlightBridgeRequestKey& launchKey,
                 std::uint32_t harmonyKeyCode, bool pressed,
                 bool normalizedToUsLayout) noexcept;
    bool sendText(const MoonlightBridgeRequestKey& launchKey,
                  const std::uint8_t* text, std::size_t size) noexcept;
    bool sendPointer(const MoonlightBridgeRequestKey& launchKey,
                     const MoonlightProductPointerRequest& request) noexcept;
    bool sendTouch(const MoonlightBridgeRequestKey& launchKey,
                   const MoonlightProductTouchRequest& request) noexcept;
    bool setInputSuspended(const MoonlightBridgeRequestKey& launchKey,
                           MoonlightInputFlushTrigger trigger,
                           bool suspended) noexcept;
    bool setTouchMode(const MoonlightBridgeRequestKey& launchKey,
                      bool direct) noexcept;
    bool setVirtualControllerMode(const MoonlightBridgeRequestKey& launchKey,
                                  bool enabled, bool editing) noexcept;
    bool sendVirtualController(
        const MoonlightBridgeRequestKey& launchKey,
        const MoonlightProductVirtualControllerRequest& request) noexcept;
    void shutdown() noexcept;

private:
    MoonlightProductStreamingRuntime() = default;
    struct State;
    State& state() noexcept;
    void completeTerminal(const MoonlightBridgeRequestKey& launchKey,
                          const MoonlightSessionKey& sessionKey) noexcept;
};

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_PRODUCT_STREAMING_RUNTIME_H
