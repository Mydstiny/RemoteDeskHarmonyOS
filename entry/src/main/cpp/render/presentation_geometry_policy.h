#pragma once

#include <cstdint>

namespace Render {

// Logical dimensions describe the remote desktop coordinate space. RAW BGRA
// presentation dimensions describe the frame most recently handed to GL;
// allocated texture dimensions are only a fallback for a retained frame. OES
// dimensions are the hardware output and are only a fallback before the
// logical size is known.
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
// protocol geometry once available; RAW software output uses the dimensions of
// the current callback frame, which may intentionally be downscaled from the
// logical stream size.
inline PresentationGeometrySize SelectPresentationGeometry(
    PresentationPathKind path,
    int logicalWidth,
    int logicalHeight,
    int rawPresentationWidth,
    int rawPresentationHeight,
    int rawTextureWidth,
    int rawTextureHeight,
    int oesOutputWidth,
    int oesOutputHeight) {
    if (path == PresentationPathKind::RawBgra) {
        if (IsValidPresentationSize(rawPresentationWidth, rawPresentationHeight)) {
            return {rawPresentationWidth, rawPresentationHeight};
        }
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

    if (IsValidPresentationSize(rawPresentationWidth, rawPresentationHeight)) {
        return {rawPresentationWidth, rawPresentationHeight};
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
