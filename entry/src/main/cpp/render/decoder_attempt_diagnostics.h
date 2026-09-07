#pragma once

#include "shared_session_context.h"
#include <algorithm>
#include <cstdint>
#include <mutex>
#include <vector>

namespace Render {

// Numeric stages are stable exported evidence, not arbitrary platform strings.
enum class DecoderAttemptStage : int32_t {
    None = 0, Create = 1, Callback = 2, Texture = 3, NativeImage = 4,
    NativeWindow = 5, Configure = 6, Surface = 7, Prepare = 8, Start = 9,
    Started = 10, FirstOutput = 11,
};

struct DecoderAttemptDiagnostic {
    uint64_t serial = 0;
    uint64_t decoderGeneration = 0;
    int32_t codec = -1;
    int32_t width = 0;
    int32_t height = 0;
    int32_t stage = 0;
    int32_t result = 0; // 0=pending, 1=success, -1=failed
    int32_t platformCode = 0;
    int32_t capabilityHardware = -1; // -1=unavailable, 0=software, 1=hardware
    int32_t capabilitySizeSupported = -1;
    int32_t outputWidth = 0;
    int32_t outputHeight = 0;
    int32_t outputPixelFormat = -1;
    uint64_t asyncErrors = 0;
    int32_t lastAsyncError = 0;
};

// Keep failure evidence independently of the codec object's lifetime. Entries
// are bounded and keyed by the entire admitted session identity; late callbacks
// can update only their original attempt, never another session's diagnostics.
class DecoderAttemptDiagnostics final {
public:
    static DecoderAttemptDiagnostics& Instance() {
        static DecoderAttemptDiagnostics instance;
        return instance;
    }
    uint64_t begin(const DecoderSessionIdentity& owner, int codec, int width, int height, uint64_t generation = 0) {
        if (!owner.valid()) return 0;
        std::lock_guard<std::mutex> lock(mutex_);
        if (entries_.size() >= 64) entries_.erase(entries_.begin());
        DecoderAttemptDiagnostic value;
        value.serial = ++serial_;
        value.decoderGeneration = generation;
        value.codec = codec;
        value.width = width;
        value.height = height;
        value.stage = static_cast<int32_t>(DecoderAttemptStage::Create);
        entries_.push_back({owner, value});
        return value.serial;
    }
    template<class Update>
    void update(const DecoderSessionIdentity& owner, uint64_t serial, Update update) {
        if (serial == 0 || !owner.valid()) return;
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto& entry : entries_) {
            if (entry.value.serial == serial && SessionOwnerMatches(entry.owner, owner)) {
                update(entry.value);
                return;
            }
        }
    }
    std::vector<DecoderAttemptDiagnostic> snapshot(const DecoderSessionIdentity& owner) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<DecoderAttemptDiagnostic> result;
        if (!owner.valid()) return result;
        for (const auto& entry : entries_) {
            if (SessionOwnerMatches(entry.owner, owner)) result.push_back(entry.value);
        }
        if (result.size() > 4) result.erase(result.begin(), result.end() - 4);
        return result;
    }
private:
    struct Entry { DecoderSessionIdentity owner; DecoderAttemptDiagnostic value; };
    std::mutex mutex_;
    uint64_t serial_ = 0;
    std::vector<Entry> entries_;
};
} // namespace Render
