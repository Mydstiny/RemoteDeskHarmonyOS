#include "moonlight/media/MoonlightAudioBridge.h"

#include <climits>
#include <cstring>
#include <memory>
#include <new>

namespace {

static_assert(sizeof(short) == sizeof(std::int16_t),
              "libopus integer PCM ABI must match int16_t");

extern "C" {
struct OpusMSDecoder;

OpusMSDecoder* opus_multistream_decoder_create(
    int sampleRate, int channels, int streams, int coupledStreams,
    const unsigned char* mapping, int* error);
int opus_multistream_decode(
    OpusMSDecoder* decoder, const unsigned char* data, int length,
    short* pcm, int frameSize, int decodeFec);
void opus_multistream_decoder_destroy(OpusMSDecoder* decoder);
const char* opus_get_version_string(void);
}

constexpr int kOpusOk = 0;
constexpr int kOpusInvalidPacket = -4;
#if !defined(RDP_MOONLIGHT_HOST_OPUS_TEST)
// The OHOS archive is the pinned 1.5.2 build with the repository's ABI-safe
// fixed suffix. Keep the check exact so an unrelated system libopus cannot be
// admitted accidentally.
constexpr char kPinnedOpusVersion[] = "libopus 1.5.2-fixed";
#endif

bool exactPinnedOpusVersion() noexcept {
    const char* version = opus_get_version_string();
#if defined(RDP_MOONLIGHT_HOST_OPUS_TEST)
    return version != nullptr && std::strncmp(version, "libopus ", 8U) == 0;
#else
    return version != nullptr && std::strcmp(version, kPinnedOpusVersion) == 0;
#endif
}

} // namespace

namespace remotedesk::moonlight {
namespace {

class MoonlightOpusDecoderPort final : public MoonlightAudioDecoderPort {
public:
    ~MoonlightOpusDecoderPort() override { destroy(); }

    MoonlightAudioDecoderConfigureStatus configure(
        const MoonlightCommonCAudioSelection& selection) noexcept override {
        destroy();
        if (!exactPinnedOpusVersion()) {
            return MoonlightAudioDecoderConfigureStatus::Failed;
        }
        int error = 0;
        decoder_ = opus_multistream_decoder_create(
            selection.opus.sampleRate, selection.opus.channelCount,
            selection.opus.streams, selection.opus.coupledStreams,
            selection.opus.mapping.data(), &error);
        if (decoder_ == nullptr || error != kOpusOk) {
            destroy();
            return MoonlightAudioDecoderConfigureStatus::Failed;
        }
        return MoonlightAudioDecoderConfigureStatus::Ready;
    }

    MoonlightAudioDecodeResult decode(
        const std::uint8_t* packet, std::size_t packetBytes, bool plc,
        std::int16_t* pcm, std::size_t frameCapacity) noexcept override {
        if (decoder_ == nullptr || pcm == nullptr || frameCapacity == 0U ||
            frameCapacity > static_cast<std::size_t>(INT_MAX) ||
            packetBytes > static_cast<std::size_t>(INT_MAX) ||
            (plc && (packet != nullptr || packetBytes != 0U)) ||
            (!plc && (packet == nullptr || packetBytes == 0U))) {
            return {MoonlightAudioDecodeStatus::Failed, 0U};
        }
        const int decoded = opus_multistream_decode(
            decoder_, plc ? nullptr : packet,
            plc ? 0 : static_cast<int>(packetBytes),
            reinterpret_cast<short*>(pcm), static_cast<int>(frameCapacity), 0);
        if (decoded == kOpusInvalidPacket) {
            return {MoonlightAudioDecodeStatus::Malformed, 0U};
        }
        if (decoded < 0) {
            return {MoonlightAudioDecodeStatus::Failed, 0U};
        }
        if (decoded == 0 || decoded > static_cast<int>(frameCapacity)) {
            return {MoonlightAudioDecodeStatus::InvalidFrameCount,
                    decoded > 0 ? static_cast<std::size_t>(decoded) : 0U};
        }
        return {MoonlightAudioDecodeStatus::Decoded,
                static_cast<std::size_t>(decoded)};
    }

    void destroy() noexcept override {
        if (decoder_ != nullptr) {
            opus_multistream_decoder_destroy(decoder_);
            decoder_ = nullptr;
        }
    }

private:
    OpusMSDecoder* decoder_ = nullptr;
};

class RejectingDormantPcmSink final : public MoonlightAudioPcmSink {
public:
    bool submit(const MoonlightAudioStreamIdentity&,
                const std::uint8_t*, std::size_t,
                std::size_t, bool) noexcept override {
        return false;
    }
};

} // namespace

std::shared_ptr<MoonlightAudioDecoderPort>
createMoonlightOpusDecoderPort() {
    try {
        return std::make_shared<MoonlightOpusDecoderPort>();
    } catch (...) {
        return nullptr;
    }
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::unique_ptr<MoonlightAudioBridge>
MoonlightAudioBridge::createWithPlatformDecoderForTesting(
    std::shared_ptr<MoonlightAudioPcmSink> sink) noexcept {
    if (!sink) {
        return nullptr;
    }
    try {
        return createForTesting(std::make_shared<MoonlightOpusDecoderPort>(),
                                std::move(sink));
    } catch (...) {
        return nullptr;
    }
}

const char* MoonlightAudioBridge::platformDecoderVersionForTesting() noexcept {
    return opus_get_version_string();
}
#endif

int MoonlightAudioBridge::productionLinkSmoke() noexcept {
    try {
        auto decoder = std::make_shared<MoonlightOpusDecoderPort>();
        auto sink = std::make_shared<RejectingDormantPcmSink>();
        auto bridge = createForTesting(decoder, sink);
        if (!bridge || !exactPinnedOpusVersion()) {
            return 1;
        }
        MoonlightCommonCAudioSelection selection;
        selection.layout = MoonlightStreamAudioLayout::Stereo;
        selection.opus.sampleRate = 48000;
        selection.opus.channelCount = 2;
        selection.opus.streams = 1;
        selection.opus.coupledStreams = 1;
        selection.opus.samplesPerFrame = 240;
        selection.opus.mapping = {0U, 1U, 0U, 0U, 0U, 0U, 0U, 0U};
        const MoonlightAudioStreamIdentity identity {{1U, 1U, 1U}, 1U};
        const auto configured = bridge->configure(identity, selection, 1U);
        if (configured.status != MoonlightAudioConfigureStatus::Configured) {
            return 2;
        }
        const auto stopped = bridge->stop(identity, 2U, std::chrono::milliseconds(0));
        return stopped.status == MoonlightAudioStopStatus::Stopped ? 0 : 3;
    } catch (...) {
        return 4;
    }
}

} // namespace remotedesk::moonlight
