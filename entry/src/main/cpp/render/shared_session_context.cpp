#include "shared_session_context.h"

#include "audio/audio_player.h"
#include "gl_renderer.h"
#include "hw_decoder.h"

namespace Render {

bool ActivateSharedSessionSinks(const DecoderSessionIdentity& owner) noexcept {
    if (!owner.valid()) {
        return false;
    }
    try {
        auto transaction = SharedSessionActivationTransaction().acquire();
        if (!transaction) {
            return false;
        }
        {
            auto transition = SharedSessionSinkOwnerLease().acquireExclusive();
            if (!transition.beginActivate(owner)) {
                return false;
            }
        }
        DecoderNapi::SetActiveSessionId(owner);
        RendererNapi::SetActiveSessionOwner(owner);
        AudioPlayerNapi::SetActiveSessionOwner(owner);
        bool committed = false;
        {
            auto transition = SharedSessionSinkOwnerLease().acquireExclusive();
            committed = transition.commit(owner);
            if (!committed) {
                (void)transition.deactivateIfActive(owner);
            }
        }
        if (committed) {
            return true;
        }
        DecoderNapi::ClearActiveSessionId(owner);
        RendererNapi::ClearActiveSessionOwner(owner);
        AudioPlayerNapi::ClearActiveSessionOwner(owner);
    } catch (...) {
    }
    return false;
}

bool DeactivateSharedSessionSinks(const DecoderSessionIdentity& owner) noexcept {
    if (!owner.valid()) {
        return false;
    }
    try {
        auto transaction = SharedSessionActivationTransaction().acquire();
        if (!transaction) {
            return false;
        }
        {
            auto transition = SharedSessionSinkOwnerLease().acquireExclusive();
            if (!transition.beginDeactivate(owner)) {
                return false;
            }
        }
        DecoderNapi::ClearActiveSessionId(owner);
        RendererNapi::ClearActiveSessionOwner(owner);
        AudioPlayerNapi::ClearActiveSessionOwner(owner);
        return true;
    } catch (...) {
        return false;
    }
}

void DeactivateAllSharedSessionSinks() noexcept {
    try {
        auto transaction = SharedSessionActivationTransaction().acquire();
        if (!transaction) {
            return;
        }
        DecoderSessionIdentity owner;
        {
            auto transition = SharedSessionSinkOwnerLease().acquireExclusive();
            owner = transition.activeSnapshot();
            if (!owner.valid() || !transition.beginDeactivate(owner)) {
                return;
            }
        }
        DecoderNapi::ClearActiveSessionId(owner);
        RendererNapi::ClearActiveSessionOwner(owner);
        AudioPlayerNapi::ClearActiveSessionOwner(owner);
    } catch (...) {
    }
}

} // namespace Render
