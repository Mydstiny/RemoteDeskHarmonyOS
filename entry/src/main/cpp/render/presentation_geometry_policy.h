#pragma once

#include <cstdint>

namespace Render {

// Logical dimensions describe the remote desktop coordinate space. RAW BGRA
// dimensions are the actual uploaded texture and must remain authoritative for
// the legacy software-decoder presentation contract. OES dimensions are the
// hardware output and are only a fallback before the logical size is known.
enum class PresentationPathKind : uint8_t {
    Unknown = 0,
    Oes = 1,
    RawBgra = 2,
};

struct PresentationGeometrySize {
    int width;
    int height;
};

inline bool IsValidPresentationSize(int width, int height) {
    return width > 0 && height > 0;
}

// Keep the two presentation contracts separate. Hardware OES output uses the
// protocol geometry once available; RAW software output keeps its established
// texture geometry because the software decoder may intentionally downscale
// the uploaded BGRA frame.
inline PresentationGeometrySize SelectPresentationGeometry(
    PresentationPathKind path,
    int logicalWidth,
    int logicalHeight,
    int rawTextureWidth,
    int rawTextureHeight,
    int oesOutputWidth,
    int oesOutputHeight) {
    if (path == PresentationPathKind::RawBgra) {
        if (IsValidPresentationSize(rawTextureWidth, rawTextureHeight)) {
            return {rawTextureWidth, rawTextureHeight};
        }
        if (IsValidPresentationSize(logicalWidth, logicalHeight)) {
            return {logicalWidth, logicalHeight};
        }
    } else if (path == PresentationPathKind::Oes) {
        if (IsValidPresentationSize(logicalWidth, logicalHeight)) {
            return {logicalWidth, logicalHeight};
        }
        if (IsValidPresentationSize(oesOutputWidth, oesOutputHeight)) {
            return {oesOutputWidth, oesOutputHeight};
        }
    } else if (IsValidPresentationSize(logicalWidth, logicalHeight)) {
        return {logicalWidth, logicalHeight};
    }

    if (IsValidPresentationSize(rawTextureWidth, rawTextureHeight)) {
        return {rawTextureWidth, rawTextureHeight};
    }
    if (IsValidPresentationSize(oesOutputWidth, oesOutputHeight)) {
        return {oesOutputWidth, oesOutputHeight};
    }
    return {0, 0};
}

} // namespace Render
