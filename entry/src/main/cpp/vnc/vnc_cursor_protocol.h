/**
 * vnc_cursor_protocol.h - bounded RFB Cursor pseudo-encoding decoder.
 */
#ifndef VNC_CURSOR_PROTOCOL_H
#define VNC_CURSOR_PROTOCOL_H

#include "vnc_pixel_format.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace VncCursorProtocol {

constexpr int kEncoding = -239;
constexpr int kMaxDimension = 384;

struct DecodedCursor {
    bool visible = false;
    uint64_t shapeId = 0;
    int width = 0;
    int height = 0;
    int hotX = 0;
    int hotY = 0;
    std::vector<uint8_t> rgba;
};

/**
 * Decode one complete Cursor pseudo-rectangle payload. A 0x0 cursor is a
 * valid hidden-cursor update and carries no pixel or mask bytes.
 */
bool decodePayload(const VncRfbProtocol::PixelFormat& format,
                   int hotX, int hotY, int width, int height,
                   const uint8_t* payload, size_t payloadSize,
                   DecodedCursor& cursor, std::string& error);

} // namespace VncCursorProtocol

#endif // VNC_CURSOR_PROTOCOL_H
