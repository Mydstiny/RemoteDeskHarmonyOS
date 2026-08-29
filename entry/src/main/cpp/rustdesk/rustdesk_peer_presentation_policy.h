#pragma once

#include "render/native_image_context_policy.h"

#include <cstddef>
#include <cctype>
#include <string_view>

namespace RustDeskPresentation {

enum class PeerPlatformCategory : uint8_t {
    Unknown = 0,
    Windows = 1,
    MacOS = 2,
    Linux = 3,
    Android = 4,
    IOS = 5,
    Other = 6,
};

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

inline PeerPlatformCategory ClassifyPeerPlatform(std::string_view platform) {
    if (platform.empty()) {
        return PeerPlatformCategory::Unknown;
    }
    if (ContainsAsciiCaseInsensitive(platform, "windows")) {
        return PeerPlatformCategory::Windows;
    }
    if (ContainsAsciiCaseInsensitive(platform, "macos") ||
        ContainsAsciiCaseInsensitive(platform, "mac os") ||
        ContainsAsciiCaseInsensitive(platform, "darwin")) {
        return PeerPlatformCategory::MacOS;
    }
    if (ContainsAsciiCaseInsensitive(platform, "linux")) {
        return PeerPlatformCategory::Linux;
    }
    if (ContainsAsciiCaseInsensitive(platform, "android")) {
        return PeerPlatformCategory::Android;
    }
    if (ContainsAsciiCaseInsensitive(platform, "ios") ||
        ContainsAsciiCaseInsensitive(platform, "iphone") ||
        ContainsAsciiCaseInsensitive(platform, "ipad")) {
        return PeerPlatformCategory::IOS;
    }
    return PeerPlatformCategory::Other;
}

inline const char* PeerPlatformCategoryName(PeerPlatformCategory category) {
    switch (category) {
        case PeerPlatformCategory::Windows: return "windows";
        case PeerPlatformCategory::MacOS: return "macos";
        case PeerPlatformCategory::Linux: return "linux";
        case PeerPlatformCategory::Android: return "android";
        case PeerPlatformCategory::IOS: return "ios";
        case PeerPlatformCategory::Other: return "other";
        case PeerPlatformCategory::Unknown:
        default: return "unknown";
    }
}

/**
 * RustDesk's PC hardware-decoded NativeImage accepts only identity and the
 * vertical texture-origin correction observed on the emulator. Computer
 * desktop orientation belongs to the encoded frame geometry, so accepting a
 * producer-side 180-degree rotation or horizontal/axis-swapping transform can
 * double-apply device-specific Surface metadata on real PC hardware. Phone
 * and Pad viewers do not sample this mode because their decoder is created
 * without desktop Surface compatibility. The peer OS label remains telemetry,
 * never an orientation switch.
 */
inline Render::NativeImagePresentationMode NativeImageModeForPeerPlatform(
    std::string_view /* platform */) {
    return Render::NativeImagePresentationMode::VerticalFlipProducerTransform;
}

} // namespace RustDeskPresentation
