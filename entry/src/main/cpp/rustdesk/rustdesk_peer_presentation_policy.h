#pragma once

#include "render/native_image_context_policy.h"

#include <cstddef>
#include <cctype>
#include <string_view>

namespace RustDeskPresentation {

inline bool ContainsAsciiCaseInsensitive(std::string_view value,
                                         std::string_view token) {
    if (token.empty() || value.size() < token.size()) {
        return false;
    }
    for (size_t start = 0; start + token.size() <= value.size(); ++start) {
        bool matched = true;
        for (size_t index = 0; index < token.size(); ++index) {
            const unsigned char left = static_cast<unsigned char>(
                value[start + index]);
            const unsigned char right = static_cast<unsigned char>(token[index]);
            if (std::tolower(left) != std::tolower(right)) {
                matched = false;
                break;
            }
        }
        if (matched) {
            return true;
        }
    }
    return false;
}

/**
 * RustDesk Windows peers require the AVCodec NativeImage producer transform on
 * the PC OES path. macOS/Linux peers and unknown platforms retain identity;
 * software-decoded frames never consume this policy.
 */
inline Render::NativeImagePresentationMode NativeImageModeForPeerPlatform(
    std::string_view platform) {
    return ContainsAsciiCaseInsensitive(platform, "windows")
        ? Render::NativeImagePresentationMode::ProducerTransform
        : Render::NativeImagePresentationMode::Identity;
}

} // namespace RustDeskPresentation
