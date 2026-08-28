/** Native security tests for the RFB Cursor pseudo-encoding. */
#include "test_runner.h"
#include "vnc/vnc_cursor_protocol.h"

#include <cstdint>
#include <string>
#include <vector>

namespace {

VncRfbProtocol::PixelFormat cursorRgba8888Format() {
    VncRfbProtocol::PixelFormat format;
    format.bitsPerPixel = 32;
    format.depth = 24;
    format.bigEndian = false;
    format.trueColor = true;
    format.redMax = 255;
    format.greenMax = 255;
    format.blueMax = 255;
    format.redShift = 16;
    format.greenShift = 8;
    format.blueShift = 0;
    return format;
}

} // namespace

RDP_TEST_CASE(vnc_cursor_payload_decodes_rgba_mask_hotspot_and_hidden_shape) {
    const VncRfbProtocol::PixelFormat format = cursorRgba8888Format();
    const std::vector<uint8_t> payload = {
        0, 0, 255, 0,
        0, 255, 0, 0,
        0x80,
    };
    VncCursorProtocol::DecodedCursor cursor;
    std::string error;
    RDP_ASSERT(VncCursorProtocol::decodePayload(
        format, 1, 0, 2, 1, payload.data(), payload.size(), cursor, error));
    RDP_ASSERT(cursor.visible);
    RDP_ASSERT_EQ(cursor.width, 2);
    RDP_ASSERT_EQ(cursor.height, 1);
    RDP_ASSERT_EQ(cursor.hotX, 1);
    RDP_ASSERT_EQ(cursor.hotY, 0);
    RDP_ASSERT(cursor.shapeId != 0);
    const std::vector<uint8_t> expected = {
        255, 0, 0, 255,
        0, 255, 0, 0,
    };
    RDP_ASSERT(cursor.rgba == expected);

    RDP_ASSERT(VncCursorProtocol::decodePayload(
        format, 17, 22, 0, 0, nullptr, 0, cursor, error));
    RDP_ASSERT(!cursor.visible);
    RDP_ASSERT(cursor.rgba.empty());
}

RDP_TEST_CASE(vnc_cursor_payload_rejects_unsafe_geometry_hotspot_and_length) {
    const VncRfbProtocol::PixelFormat format = cursorRgba8888Format();
    const std::vector<uint8_t> payload(9, 0);
    VncCursorProtocol::DecodedCursor cursor;
    std::string error;
    RDP_ASSERT(!VncCursorProtocol::decodePayload(
        format, 2, 0, 2, 1, payload.data(), payload.size(), cursor, error));
    RDP_ASSERT(!VncCursorProtocol::decodePayload(
        format, 0, 0, VncCursorProtocol::kMaxDimension + 1, 1,
        payload.data(), payload.size(), cursor, error));
    RDP_ASSERT(!VncCursorProtocol::decodePayload(
        format, 0, 0, 2, 1, payload.data(), payload.size() - 1, cursor, error));
    RDP_ASSERT(!VncCursorProtocol::decodePayload(
        format, 0, 0, 0, 0, payload.data(), 1, cursor, error));
}

RDP_TEST_CASE(vnc_cursor_payload_treats_an_all_transparent_mask_as_hidden) {
    const VncRfbProtocol::PixelFormat format = cursorRgba8888Format();
    const std::vector<uint8_t> payload = {
        0, 0, 255, 0,
        0, 255, 0, 0,
        0x00,
    };
    VncCursorProtocol::DecodedCursor cursor;
    std::string error;
    RDP_ASSERT(VncCursorProtocol::decodePayload(
        format, 0, 0, 2, 1, payload.data(), payload.size(), cursor, error));
    RDP_ASSERT(!cursor.visible);
    RDP_ASSERT_EQ(cursor.width, 2);
    RDP_ASSERT_EQ(cursor.height, 1);
    RDP_ASSERT_EQ(cursor.rgba.size(), 8U);
    RDP_ASSERT_EQ(cursor.rgba[3], 0U);
    RDP_ASSERT_EQ(cursor.rgba[7], 0U);
}
