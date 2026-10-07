#include "shared_session_context.h"

#include "audio/audio_player.h"
#include "gl_renderer.h"
#include "hw_decoder.h"

#include <vector>

namespace Render {

bool ActivateSharedSessionSinks(const DecoderSessionIdentity& owner, bool exclusive) noexcept {
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
            if (!transition.beginActivate(owner, exclusive)) {
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
        // Every live picture session (several may share the sinks), each released on its own.
        std::vector<DecoderSessionIdentity> owners;
        {
            auto transition = SharedSessionSinkOwnerLease().acquireExclusive();
            owners = transition.owners();
            for (const DecoderSessionIdentity& owner : owners) {
                (void)transition.beginDeactivate(owner);
            }
        }
        for (const DecoderSessionIdentity& owner : owners) {
            DecoderNapi::ClearActiveSessionId(owner);
            RendererNapi::ClearActiveSessionOwner(owner);
            AudioPlayerNapi::ClearActiveSessionOwner(owner);
        }
    } catch (...) {
    }
}

} // namespace Render
