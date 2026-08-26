#include "moonlight/media/MoonlightAudioPlayerSink.h"

#include "audio/audio_player.h"

#include <memory>

namespace remotedesk::moonlight {
namespace {

class ExistingAudioPlayerPort final : public MoonlightAudioPlayerPort {
  public:
    bool ownerReady(const Render::DecoderSessionIdentity& owner) noexcept override {
        return Render::SharedSessionSinkOwnerLease().accepts(owner);
    }

    int submit(const Render::DecoderSessionIdentity& owner, const std::uint8_t* pcm,
               std::size_t pcmBytes, int sampleRate, int channels) noexcept override {
        return AudioPlayerNapi::DispatchActiveNative(owner, pcm, pcmBytes, sampleRate, channels);
    }

    bool suspendAndFlush(const Render::DecoderSessionIdentity& owner) noexcept override {
        auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
        if (!ownerLease) {
            return false;
        }
        // No player before first PCM is already flushed; owner admission is
        // authoritative while the shared function handles the live case.
        (void)AudioPlayerNapi::SuspendActiveNative(owner);
        return true;
    }

    bool destroyAndFlush(const Render::DecoderSessionIdentity& owner) noexcept override {
        if (!owner.valid()) {
            return false;
        }
        const std::shared_ptr<AudioPlayer> player = AudioPlayerNapi::TakeActiveNative(owner);
        if (player != nullptr) {
            player->Destroy();
        }
        return true;
    }
};

} // namespace

std::shared_ptr<MoonlightAudioPlayerSink> MoonlightAudioPlayerSink::createProduction() noexcept {
    try {
        return createForTesting(std::make_shared<ExistingAudioPlayerPort>());
    } catch (...) {
        return nullptr;
    }
}

} // namespace remotedesk::moonlight
