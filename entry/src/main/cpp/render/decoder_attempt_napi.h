#pragma once
#include "decoder_attempt_diagnostics.h"
#include <napi/native_api.h>

namespace Render {
inline void SetDecoderAttemptEvidence(napi_env env, napi_value object,
    const DecoderSessionIdentity& owner) {
    const auto attempts = DecoderAttemptDiagnostics::Instance().snapshot(owner);
    napi_value array;
    napi_create_array_with_length(env, attempts.size(), &array);
    for (size_t index = 0; index < attempts.size(); ++index) {
        napi_value entry;
        napi_create_object(env, &entry);
        const auto set = [=](const char* key, int64_t number) {
            napi_value value;
            napi_create_int64(env, number, &value);
            napi_set_named_property(env, entry, key, value);
        };
        const auto& a = attempts[index];
        set("serial", static_cast<int64_t>(a.serial));
        set("decoderGeneration", static_cast<int64_t>(a.decoderGeneration));
        set("codec", a.codec);
        set("width", a.width);
        set("height", a.height);
        set("stage", a.stage);
        set("result", a.result);
        set("platformCode", a.platformCode);
        set("capabilityHardware", a.capabilityHardware);
        set("capabilitySizeSupported", a.capabilitySizeSupported);
        set("outputWidth", a.outputWidth);
        set("outputHeight", a.outputHeight);
        set("outputPixelFormat", a.outputPixelFormat);
        set("asyncErrors", static_cast<int64_t>(a.asyncErrors));
        set("lastAsyncError", a.lastAsyncError);
        napi_set_element(env, array, index, entry);
    }
    napi_set_named_property(env, object, "decoderAttempts", array);
}
} // namespace Render
