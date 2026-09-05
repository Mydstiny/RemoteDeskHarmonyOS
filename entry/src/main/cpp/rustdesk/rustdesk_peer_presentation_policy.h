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
 * RustDesk upstream identifies this class of failure as viewer texture-path
 * behavior, not remote operating-system orientation. Our device evidence also
 * shows the same Windows peer label and FlipY producer class can require
 * different treatment on different HarmonyOS PC graphics stacks. Therefore a
 * peer-platform switch is unsafe. Keep the producer contract restricted to
 * identity or a vertical texture-origin correction, then apply explicit local
 * visual/control axes in the renderer. Phone and Pad viewers never sample this
 * desktop compatibility policy.
 */
inline Render::NativeImagePresentationMode NativeImageModeForPeerPlatform(
    std::string_view /* platform */) {
    return Render::NativeImagePresentationMode::VerticalFlipProducerTransform;
}

} // namespace RustDeskPresentation
