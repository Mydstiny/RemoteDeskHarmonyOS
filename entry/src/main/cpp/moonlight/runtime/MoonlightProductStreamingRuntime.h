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
    // Crash-recovery launches must neutralize the previous host input state
    // before any fresh physical, virtual, keyboard, pointer, or touch input is
    // admitted. Normal launches leave this false and pay no reset cost.
    bool resetRemoteInputBeforeAdmission = false;
    // Local presentation capability only. It is never inferred from the
    // remote host or persisted as a host setting.
    bool desktopSurfaceCompatibility = false;
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

constexpr bool moonlightProductTerminalInputMayBeStuck(
    bool activationAttempted, bool teardownObserved,
    bool localCleanupComplete, bool remoteNeutral) noexcept {
    // Once input activation was attempted, missing teardown proof is itself
    // uncertainty. Local-only cleanup must never masquerade as a Sunshine-side
    // neutral receipt, and an inconsistent remote-only result also fails safe.
    return activationAttempted &&
        (!teardownObserved || !localCleanupComplete || !remoteNeutral);
}

constexpr bool moonlightProductStopReachedTerminal(
    MoonlightStopStatus status) noexcept {
    // DriverFailure is still terminal: MoonlightSessionOwner has observed the
    // terminal phase and reaped the exact owner before returning it. The
    // failure remains visible in the receipt, but it must not keep the
    // process-wide media/input owner occupied forever.
    return status == MoonlightStopStatus::Stopped ||
        status == MoonlightStopStatus::AlreadyTerminal ||
        status == MoonlightStopStatus::DriverFailure;
}

constexpr std::uint64_t moonlightProductPresentedFrameProgress(
    bool diagnosticsMatched, std::uint64_t acceptedVideoFrames,
    std::uint64_t renderedOutputBuffers, std::uint64_t nativeImageFrames,
    std::uint64_t rendererPresentedFrames) noexcept {
    if (!diagnosticsMatched || acceptedVideoFrames == 0U ||
        renderedOutputBuffers == 0U || nativeImageFrames == 0U ||
        rendererPresentedFrames == 0U) {
        return 0U;
    }
    // A decoded NativeImage is not proof that the current XComponent Surface
    // actually presented it: the decoder callback counter advances even when
    // the renderer rejects a stale generation or eglSwapBuffers() fails. Only
    // the renderer acknowledgement may open a fresh presentation barrier.
    return rendererPresentedFrames;
}

constexpr bool moonlightProductFirstFrameProven(
    bool sourceFirstFrameReady, bool diagnosticsMatched,
    std::uint64_t acceptedVideoFrames,
    std::uint64_t renderedOutputBuffers, std::uint64_t nativeImageFrames,
    std::uint64_t rendererPresentedFrames) noexcept {
    return sourceFirstFrameReady ||
        moonlightProductPresentedFrameProgress(
            diagnosticsMatched, acceptedVideoFrames,
            renderedOutputBuffers, nativeImageFrames,
            rendererPresentedFrames) > 0U;
}

constexpr bool moonlightProductVideoReady(
    bool sourceVideoReady, bool firstFrameProven) noexcept {
    // A frame that has crossed the exact-session decoder, NativeImage, and
    // renderer presentation fences is stronger evidence than the transient
    // media-lane "started" flag. Some API 23 devices can publish that lane
    // flag as false while the hardware pipeline is already presenting. Do not
    // let the product coordinator discard the proven frame and fire its
    // 30-second first-frame watchdog against a healthy stream.
    return sourceVideoReady || firstFrameProven;
}

constexpr bool moonlightProductSessionFirstFrameReady(
    bool sessionFirstFrameReady, bool presentationFrameReady) noexcept {
    // Session admission is historical truth: once this exact launch has
    // presented a frame it must not regress merely because its current
    // Surface is suspended for background/PIP transfer. Fresh-Surface
    // admission is represented separately by presentationFrameReady.
    return sessionFirstFrameReady || presentationFrameReady;
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
    bool inputMayBeStuck = false;
    bool presentationFrameReady = false;
    bool firstFrameReady = false;
    bool terminal = false;
    std::uint64_t lastSequence = 0U;
    std::uint64_t sampledAtMonotonicMs = 0U;
    std::uint64_t acceptedVideoFrames = 0U;
    std::uint64_t droppedVideoFrames = 0U;
    std::uint64_t acceptedVideoBytes = 0U;
    std::uint64_t rendererPresentedFrames = 0U;
    std::uint64_t acceptedAudioPackets = 0U;
    std::uint64_t rejectedAudioPackets = 0U;
    std::uint64_t acceptedAudioBytes = 0U;
    std::uint64_t acceptedInputEvents = 0U;
    std::uint64_t rejectedInputEvents = 0U;
    std::size_t decoderQueueDepth = 0U;
    std::uint64_t decoderInputDroppedFrames = 0U;
    std::uint64_t decoderWaitKeyframeDrops = 0U;
    std::uint64_t decoderInputTruncated = 0U;
    std::uint64_t decoderRenderOutputFailures = 0U;
    std::uint64_t decoderSurfaceUpdateFailures = 0U;
    std::uint64_t decoderSurfaceCoalescedNotifications = 0U;
    std::int64_t decoderCodecLatencyMs = 0;
    std::int64_t decoderCodecLatencyMaxMs = 0;
    bool decoderLowLatencyEnabled = false;
    std::int32_t streamWidth = 0;
    std::int32_t streamHeight = 0;
    std::int32_t targetFps = 0;
    std::int32_t configuredBitrateKbps = 0;
    MoonlightStreamCodec codec = MoonlightStreamCodec::H264;
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
    bool suspendSurface(const MoonlightBridgeRequestKey& launchKey) noexcept;
    bool rebindSurface(const MoonlightBridgeRequestKey& launchKey,
                       std::int64_t rendererHandle) noexcept;
    bool setAudioPaused(const MoonlightBridgeRequestKey& launchKey,
                        bool paused) noexcept;
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
    void recordTerminalInputTeardown(
        const MoonlightBridgeRequestKey& launchKey,
        const MoonlightSessionKey& sessionKey,
        bool localCleanupComplete, bool remoteNeutral) noexcept;
};

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_PRODUCT_STREAMING_RUNTIME_H
