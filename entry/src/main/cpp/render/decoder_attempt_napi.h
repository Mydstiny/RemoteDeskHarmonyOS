#pragma once
#include "decoder_attempt_diagnostics.h"
#include "video_orientation_self_test.h"
#include <string>
#include <vector>
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
        set("outputStride", a.outputStride);
        set("outputSliceHeight", a.outputSliceHeight);
        set("outputCropTop", a.outputCropTop);
        set("outputCropBottom", a.outputCropBottom);
        set("outputCropLeft", a.outputCropLeft);
        set("outputCropRight", a.outputCropRight);
        set("outputRotation", a.outputRotation);
        set("outputTransformType", a.outputTransformType);
        set("bufferTransform", a.bufferTransform);
        set("producerV1Class", a.producerV1Class);
        set("orientationCorrection", a.orientationCorrection);
        set("streamNalMaskLow", a.streamNalMaskLow);
        set("streamNalMaskHigh", a.streamNalMaskHigh);
        set("streamSeiMaskLow", a.streamSeiMaskLow);
        set("streamSeiMaskHigh", a.streamSeiMaskHigh);
        set("streamDisplayOrientation", a.streamDisplayOrientation);
        set("streamInspectedFrames", a.streamInspectedFrames);
        napi_set_element(env, array, index, entry);
    }
    napi_set_named_property(env, object, "decoderAttempts", array);
}

/** The orientation self-tests run in this process, for the diagnostic snapshot. */
inline void SetOrientationSelfTestEvidence(napi_env env, napi_value object) {
    const std::vector<OrientationSelfTestResult> results = AllVideoOrientationSelfTests();
    napi_value array;
    napi_create_array_with_length(env, results.size(), &array);
    for (size_t index = 0; index < results.size(); ++index) {
        napi_value entry;
        napi_create_object(env, &entry);
        const auto set = [=](const char* key, int64_t number) {
            napi_value value;
            napi_create_int64(env, number, &value);
            napi_set_named_property(env, entry, key, value);
        };
        const auto text = [=](const char* key, const std::string& valueText) {
            napi_value value;
            napi_create_string_utf8(env, valueText.c_str(), valueText.size(), &value);
            napi_set_named_property(env, entry, key, value);
        };
        const auto& r = results[index];
        set("codec", r.codec);
        set("mode", static_cast<int64_t>(r.mode));
        set("stage", static_cast<int64_t>(r.stage));
        set("platformCode", r.platformCode);
        set("hardware", r.hardware);
        set("outputWidth", r.outputWidth);
        set("outputHeight", r.outputHeight);
        set("outputStride", r.outputStride);
        set("outputSliceHeight", r.outputSliceHeight);
        set("outputPixelFormat", r.outputPixelFormat);
        set("outputRotation", r.outputRotation);
        set("outputTransformType", r.outputTransformType);
        set("bufferTransform", r.bufferTransform);
        set("v2Class", static_cast<int64_t>(r.v2Class));
        set("v2ReadResult", r.v2ReadResult);
        set("v1Class", static_cast<int64_t>(r.v1Class));
        set("v1ReadResult", r.v1ReadResult);
        set("identityOrientation", static_cast<int64_t>(r.identityOrientation));
        set("appliedOrientation", static_cast<int64_t>(r.appliedOrientation));
        set("identityCorners0", r.identityCorners[0]);
        set("identityCorners1", r.identityCorners[1]);
        set("identityCorners2", r.identityCorners[2]);
        set("identityCorners3", r.identityCorners[3]);
        set("appliedCorners0", r.appliedCorners[0]);
        set("appliedCorners1", r.appliedCorners[1]);
        set("appliedCorners2", r.appliedCorners[2]);
        set("appliedCorners3", r.appliedCorners[3]);
        set("elapsedMs", r.elapsedMs);
        text("decoderName", r.decoderName);
        text("glVendor", r.glVendor);
        text("glRenderer", r.glRenderer);
        text("glVersion", r.glVersion);
        napi_set_element(env, array, index, entry);
    }
    napi_set_named_property(env, object, "orientationSelfTests", array);
}
} // namespace Render
