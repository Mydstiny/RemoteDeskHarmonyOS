/**
 * vnc_pixel_format.h - negotiated RFB true-colour pixel format.
 */
#ifndef VNC_PIXEL_FORMAT_H
#define VNC_PIXEL_FORMAT_H

#include <cstdint>

namespace VncRfbProtocol {

struct PixelFormat {
    uint8_t bitsPerPixel = 32;
    uint8_t depth = 24;
    bool bigEndian = false;
    bool trueColor = true;
    uint16_t redMax = 255;
    uint16_t greenMax = 255;
    uint16_t blueMax = 255;
    uint8_t redShift = 16;
    uint8_t greenShift = 8;
    uint8_t blueShift = 0;
};

} // namespace VncRfbProtocol

#endif // VNC_PIXEL_FORMAT_H
