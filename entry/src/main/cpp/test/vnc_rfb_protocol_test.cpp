/** Native tests for the shared RFB and UltraVNC wire contracts. */
#include "test_runner.h"
#include "vnc/vnc_rfb_protocol.h"
#include "vnc/vnc_transport_policy.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <string>
#include <vector>
#include <zlib.h>

namespace {

VncRfbProtocol::PixelFormat rgba8888Format() {
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

VncRfbProtocol::PixelFormat rgb565Format() {
    VncRfbProtocol::PixelFormat format;
    format.bitsPerPixel = 16;
    format.depth = 16;
    format.bigEndian = false;
    format.trueColor = true;
    format.redMax = 31;
    format.greenMax = 63;
    format.blueMax = 31;
    format.redShift = 11;
    format.greenShift = 5;
    format.blueShift = 0;
    return format;
}

VncRfbProtocol::PixelFormat rgb332Format() {
    VncRfbProtocol::PixelFormat format;
    format.bitsPerPixel = 8;
    format.depth = 8;
    format.bigEndian = false;
    format.trueColor = true;
    format.redMax = 7;
    format.greenMax = 7;
    format.blueMax = 3;
    format.redShift = 5;
    format.greenShift = 2;
    format.blueShift = 0;
    return format;
}

std::vector<uint8_t> deflateSyncFlush(z_stream& stream,
                                      const std::vector<uint8_t>& input) {
    std::vector<uint8_t> output;
    stream.next_in = const_cast<Bytef*>(
        reinterpret_cast<const Bytef*>(input.data()));
    stream.avail_in = static_cast<uInt>(input.size());
    std::array<uint8_t, 256> buffer = {0};
    do {
        stream.next_out = reinterpret_cast<Bytef*>(buffer.data());
        stream.avail_out = static_cast<uInt>(buffer.size());
        const int result = deflate(&stream, Z_SYNC_FLUSH);
        if (result != Z_OK) {
            return {};
        }
        output.insert(output.end(), buffer.begin(),
                      buffer.begin() + static_cast<std::ptrdiff_t>(
                          buffer.size() - stream.avail_out));
    } while (stream.avail_in != 0 || stream.avail_out == 0);
    return output;
}

} // namespace

RDP_TEST_CASE(vnc_rfb_client_init_is_shared_one_byte) {
    RDP_ASSERT_EQ(VncRfbProtocol::clientInitSharedFlag(), static_cast<uint8_t>(1));
}

RDP_TEST_CASE(vnc_rfb_minor_normalization_is_fail_closed) {
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(3), 3);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(7), 7);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(8), 8);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(4), 3);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(6), 3);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(9), 3);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(889), 3);
    RDP_ASSERT(VncRfbProtocol::keepsLocalCursorDuringBootstrap(3));
    RDP_ASSERT(!VncRfbProtocol::keepsLocalCursorDuringBootstrap(7));
    RDP_ASSERT(!VncRfbProtocol::keepsLocalCursorDuringBootstrap(8));
}

RDP_TEST_CASE(vnc_rfb_security_result_contract_matches_version) {
    RDP_ASSERT(!VncRfbProtocol::securityResultExpected(3, 1));
    RDP_ASSERT(!VncRfbProtocol::securityResultExpected(7, 1));
    RDP_ASSERT(VncRfbProtocol::securityResultExpected(8, 1));
    RDP_ASSERT(VncRfbProtocol::securityResultExpected(3, 2));
    RDP_ASSERT(VncRfbProtocol::securityResultExpected(7, 2));
    RDP_ASSERT(VncRfbProtocol::securityResultExpected(8, 2));
}

RDP_TEST_CASE(vnc_framebuffer_update_request_has_exact_rfb_wire_layout) {
    const std::vector<uint8_t> initial =
        VncRfbProtocol::buildFramebufferUpdateRequest(false, 1920, 1080);
    RDP_ASSERT_EQ(initial.size(), static_cast<size_t>(10));
    const std::vector<uint8_t> expectedInitial = {
        3, 0, 0, 0, 0, 0, 7, 128, 4, 56,
    };
    RDP_ASSERT(initial == expectedInitial);

    const std::vector<uint8_t> incremental =
        VncRfbProtocol::buildFramebufferUpdateRequest(true, 2560, 1600);
    RDP_ASSERT_EQ(incremental.size(), static_cast<size_t>(10));
    const std::vector<uint8_t> expectedIncremental = {
        3, 1, 0, 0, 0, 0, 10, 0, 6, 64,
    };
    RDP_ASSERT(incremental == expectedIncremental);
}

RDP_TEST_CASE(vnc_pointer_wheel_burst_preserves_buttons_direction_and_coordinates) {
    const std::vector<uint8_t> positive =
        VncRfbProtocol::buildPointerWheelBurst(1, -4, 999, 3, 640, 480);
    RDP_ASSERT_EQ(positive.size(), static_cast<size_t>(36));
    const std::vector<uint8_t> expectedStep = {
        5, 9, 0, 0, 1, 223,
        5, 1, 0, 0, 1, 223,
    };
    for (size_t offset = 0; offset < positive.size(); offset += expectedStep.size()) {
        RDP_ASSERT(std::equal(expectedStep.begin(), expectedStep.end(), positive.begin() + offset));
    }

    const std::vector<uint8_t> negative =
        VncRfbProtocol::buildPointerWheelBurst(2, 300, 200, -2, 640, 480);
    RDP_ASSERT_EQ(negative.size(), static_cast<size_t>(24));
    RDP_ASSERT_EQ(negative[1], static_cast<uint8_t>(18));
    RDP_ASSERT_EQ(negative[7], static_cast<uint8_t>(2));
    RDP_ASSERT_EQ(negative[2], static_cast<uint8_t>(1));
    RDP_ASSERT_EQ(negative[3], static_cast<uint8_t>(44));
    RDP_ASSERT_EQ(negative[4], static_cast<uint8_t>(0));
    RDP_ASSERT_EQ(negative[5], static_cast<uint8_t>(200));

    const std::vector<uint8_t> capped =
        VncRfbProtocol::buildPointerWheelBurst(7, 1, 1, 1000, 2, 2);
    RDP_ASSERT_EQ(capped.size(),
        static_cast<size_t>(VncRfbProtocol::kMaxWheelBurstSteps * 12));
    RDP_ASSERT_EQ(capped[1], static_cast<uint8_t>(15));
    RDP_ASSERT_EQ(capped[7], static_cast<uint8_t>(7));
    const std::vector<uint8_t> tenTimesMouse =
        VncRfbProtocol::buildPointerWheelBurst(0, 10, 20, 80, 100, 100);
    RDP_ASSERT_EQ(tenTimesMouse.size(), static_cast<size_t>(80 * 12));
    for (size_t offset = 0; offset < tenTimesMouse.size(); offset += 12U) {
        RDP_ASSERT_EQ(tenTimesMouse[offset + 1], static_cast<uint8_t>(8));
        RDP_ASSERT_EQ(tenTimesMouse[offset + 7], static_cast<uint8_t>(0));
    }
    RDP_ASSERT(VncRfbProtocol::buildPointerWheelBurst(0, 0, 0, 0, 1, 1).empty());
}

RDP_TEST_CASE(vnc_pixel_format_policy_is_bounded_and_wire_exact) {
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("32", "speed", 9000000), 32);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("16", "quality", 100), 16);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("8", "balanced", 100), 8);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "speed", 100), 8);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "speed",
        9ULL * 1024ULL * 1024ULL), 8);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "balanced",
        5ULL * 1024ULL * 1024ULL), 8);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "balanced",
        4ULL * 1024ULL * 1024ULL), 32);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "balanced",
        5ULL * 1024ULL * 1024ULL, 3), 16);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "speed", 100, 3), 16);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("8", "speed", 100, 3), 16);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("16", "speed", 100, 3), 16);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("32", "speed", 100, 3), 32);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "quality", 100), 32);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "quality",
        5ULL * 1024ULL * 1024ULL), 32);

    const std::vector<uint8_t> format16 = VncRfbProtocol::buildSetPixelFormat(16);
    RDP_ASSERT_EQ(format16.size(), static_cast<size_t>(20));
    RDP_ASSERT_EQ(format16[0], static_cast<uint8_t>(0));
    RDP_ASSERT_EQ(format16[4], static_cast<uint8_t>(16));
    RDP_ASSERT_EQ(format16[5], static_cast<uint8_t>(16));
    RDP_ASSERT_EQ(format16[9], static_cast<uint8_t>(31));
    RDP_ASSERT_EQ(format16[11], static_cast<uint8_t>(63));
    RDP_ASSERT_EQ(format16[14], static_cast<uint8_t>(11));

    const std::vector<uint8_t> format8 = VncRfbProtocol::buildSetPixelFormat(8);
    RDP_ASSERT_EQ(format8.size(), static_cast<size_t>(20));
    RDP_ASSERT_EQ(format8[4], static_cast<uint8_t>(8));
    RDP_ASSERT_EQ(format8[5], static_cast<uint8_t>(8));
    RDP_ASSERT_EQ(format8[9], static_cast<uint8_t>(7));
    RDP_ASSERT_EQ(format8[11], static_cast<uint8_t>(7));
    RDP_ASSERT_EQ(format8[13], static_cast<uint8_t>(3));
    RDP_ASSERT_EQ(format8[14], static_cast<uint8_t>(5));
    RDP_ASSERT_EQ(format8[15], static_cast<uint8_t>(2));
}

RDP_TEST_CASE(vnc_set_encodings_advertises_cursor_and_bounded_zrle_with_raw_fallback) {
    const std::vector<uint8_t> automatic =
        VncRfbProtocol::buildSetEncodings("auto");
    const std::vector<uint8_t> expectedAutomatic = {
        2, 0, 0, 6,
        0, 0, 0, 16,
        0, 0, 0, 1,
        0, 0, 0, 0,
        255, 255, 255, 17,
        255, 255, 255, 33,
        255, 255, 255, 32,
    };
    RDP_ASSERT(automatic == expectedAutomatic);
    RDP_ASSERT(VncRfbProtocol::buildSetEncodings("zrle") == expectedAutomatic);

    const std::vector<uint8_t> raw =
        VncRfbProtocol::buildSetEncodings("raw");
    const std::vector<uint8_t> expectedRaw = {
        2, 0, 0, 5,
        0, 0, 0, 1,
        0, 0, 0, 0,
        255, 255, 255, 17,
        255, 255, 255, 33,
        255, 255, 255, 32,
    };
    RDP_ASSERT(raw == expectedRaw);
}

RDP_TEST_CASE(vnc_text_input_uses_key_events_independent_of_clipboard_policy) {
    RDP_ASSERT(VncRfbProtocol::canSendTextInput(false, true, true));
    RDP_ASSERT(VncRfbProtocol::canSendTextInput(false, false, true));
    RDP_ASSERT(!VncRfbProtocol::canSendTextInput(true, true, true));
    RDP_ASSERT(!VncRfbProtocol::canSendTextInput(true, false, true));
    RDP_ASSERT(!VncRfbProtocol::canSendTextInput(false, true, false));

    std::vector<uint8_t> packet;
    std::string error;
    RDP_ASSERT(VncRfbProtocol::buildTextKeyEvents("A", packet, error));
    const std::vector<uint8_t> expected = {
        4, 1, 0, 0, 0, 0, 0, 0x41,
        4, 0, 0, 0, 0, 0, 0, 0x41,
    };
    RDP_ASSERT(packet == expected);
}

RDP_TEST_CASE(vnc_text_input_maps_latin1_and_unicode_keysyms) {
    std::vector<uint8_t> packet;
    std::string error;
    RDP_ASSERT(VncRfbProtocol::buildTextKeyEvents(
        std::string("A\xC3\xA9\xE4\xB8\xAD"), packet, error));
    RDP_ASSERT_EQ(packet.size(), static_cast<size_t>(48));
    RDP_ASSERT_EQ(packet[7], static_cast<uint8_t>(0x41));
    RDP_ASSERT_EQ(packet[23], static_cast<uint8_t>(0xE9));
    RDP_ASSERT_EQ(packet[36], static_cast<uint8_t>(0x01));
    RDP_ASSERT_EQ(packet[37], static_cast<uint8_t>(0x00));
    RDP_ASSERT_EQ(packet[38], static_cast<uint8_t>(0x4E));
    RDP_ASSERT_EQ(packet[39], static_cast<uint8_t>(0x2D));
    RDP_ASSERT_EQ(packet[44], static_cast<uint8_t>(0x01));
    RDP_ASSERT_EQ(packet[45], static_cast<uint8_t>(0x00));
    RDP_ASSERT_EQ(packet[46], static_cast<uint8_t>(0x4E));
    RDP_ASSERT_EQ(packet[47], static_cast<uint8_t>(0x2D));
}

RDP_TEST_CASE(vnc_text_input_rejects_malformed_utf8_without_partial_packets) {
    const std::vector<std::string> malformed = {
        std::string("\xC0\xAF", 2),
        std::string("\xE2\x82", 2),
        std::string("\xED\xA0\x80", 3),
        std::string("\xF4\x90\x80\x80", 4),
    };
    for (const std::string& text : malformed) {
        std::vector<uint8_t> packet = {1, 2, 3};
        std::string error;
        RDP_ASSERT(!VncRfbProtocol::buildTextKeyEvents(text, packet, error));
        RDP_ASSERT(packet.empty());
        RDP_ASSERT(!error.empty());
    }
}

RDP_TEST_CASE(vnc_zrle_decodes_negotiated_8_16_and_big_endian_32_bit_pixels) {
    std::string error;
    std::vector<uint8_t> rgba;

    const VncRfbProtocol::PixelFormat format8 = rgb332Format();
    const std::vector<uint8_t> solid8 = {1, 0xE0};
    RDP_ASSERT_EQ(VncRfbProtocol::compactPixelBytes(format8), static_cast<size_t>(1));
    RDP_ASSERT(VncRfbProtocol::decodeZrleTiles(
        format8, 1, 1, solid8.data(), solid8.size(), rgba, error));
    RDP_ASSERT(rgba == std::vector<uint8_t>({255, 0, 0, 255}));

    const VncRfbProtocol::PixelFormat format16 = rgb565Format();
    const std::vector<uint8_t> solid16 = {1, 0xE0, 0x07};
    RDP_ASSERT_EQ(VncRfbProtocol::compactPixelBytes(format16), static_cast<size_t>(2));
    RDP_ASSERT(VncRfbProtocol::decodeZrleTiles(
        format16, 1, 1, solid16.data(), solid16.size(), rgba, error));
    RDP_ASSERT(rgba == std::vector<uint8_t>({0, 255, 0, 255}));

    VncRfbProtocol::PixelFormat bigEndian = rgba8888Format();
    bigEndian.bigEndian = true;
    const std::vector<uint8_t> solid32BigEndian = {1, 0x00, 0x00, 0xFF};
    RDP_ASSERT_EQ(VncRfbProtocol::compactPixelBytes(bigEndian), static_cast<size_t>(3));
    RDP_ASSERT(VncRfbProtocol::decodeZrleTiles(
        bigEndian, 1, 1, solid32BigEndian.data(), solid32BigEndian.size(), rgba, error));
    RDP_ASSERT(rgba == std::vector<uint8_t>({0, 0, 255, 255}));
}

RDP_TEST_CASE(vnc_zrle_decodes_raw_solid_packed_and_rle_tiles) {
    const VncRfbProtocol::PixelFormat format = rgba8888Format();
    RDP_ASSERT_EQ(VncRfbProtocol::compactPixelBytes(format), static_cast<size_t>(3));
    std::string error;
    std::vector<uint8_t> rgba;

    const std::vector<uint8_t> raw = {
        0,
        0, 0, 255,
        255, 0, 0,
    };
    RDP_ASSERT(VncRfbProtocol::decodeZrleTiles(
        format, 2, 1, raw.data(), raw.size(), rgba, error));
    RDP_ASSERT(rgba == std::vector<uint8_t>({
        255, 0, 0, 255,
        0, 0, 255, 255,
    }));

    const std::vector<uint8_t> solid = {1, 0, 255, 0};
    RDP_ASSERT(VncRfbProtocol::decodeZrleTiles(
        format, 3, 1, solid.data(), solid.size(), rgba, error));
    RDP_ASSERT(rgba == std::vector<uint8_t>({
        0, 255, 0, 255,
        0, 255, 0, 255,
        0, 255, 0, 255,
    }));

    const std::vector<uint8_t> packed = {
        2,
        0, 0, 255,
        255, 0, 0,
        0x40,
    };
    RDP_ASSERT(VncRfbProtocol::decodeZrleTiles(
        format, 2, 1, packed.data(), packed.size(), rgba, error));
    RDP_ASSERT(rgba == std::vector<uint8_t>({
        255, 0, 0, 255,
        0, 0, 255, 255,
    }));

    const std::vector<uint8_t> plainRle = {
        128,
        0, 0, 255,
        2,
    };
    RDP_ASSERT(VncRfbProtocol::decodeZrleTiles(
        format, 3, 1, plainRle.data(), plainRle.size(), rgba, error));
    RDP_ASSERT_EQ(rgba.size(), static_cast<size_t>(12));
    RDP_ASSERT_EQ(rgba[0], static_cast<uint8_t>(255));
    RDP_ASSERT_EQ(rgba[8], static_cast<uint8_t>(255));

    const std::vector<uint8_t> paletteRle = {
        130,
        0, 0, 255,
        255, 0, 0,
        0x80, 1,
        1,
    };
    RDP_ASSERT(VncRfbProtocol::decodeZrleTiles(
        format, 3, 1, paletteRle.data(), paletteRle.size(), rgba, error));
    RDP_ASSERT(rgba == std::vector<uint8_t>({
        255, 0, 0, 255,
        255, 0, 0, 255,
        0, 0, 255, 255,
    }));
}

RDP_TEST_CASE(vnc_zrle_direct_bgra_decode_respects_stride_and_padding) {
    const VncRfbProtocol::PixelFormat format = rgba8888Format();
    const std::vector<uint8_t> solidRed = {1, 0, 0, 255};
    constexpr size_t stride = 16;
    std::vector<uint8_t> bgra(stride * 2U, 0xA5);
    std::string error;
    RDP_ASSERT(VncRfbProtocol::decodeZrleTilesToBgra(
        format, 3, 2, solidRed.data(), solidRed.size(),
        bgra.data(), bgra.size(), stride, error));
    for (size_t row = 0; row < 2; ++row) {
        for (size_t column = 0; column < 3; ++column) {
            const size_t offset = row * stride + column * 4U;
            RDP_ASSERT_EQ(bgra[offset], static_cast<uint8_t>(0));
            RDP_ASSERT_EQ(bgra[offset + 1], static_cast<uint8_t>(0));
            RDP_ASSERT_EQ(bgra[offset + 2], static_cast<uint8_t>(255));
            RDP_ASSERT_EQ(bgra[offset + 3], static_cast<uint8_t>(255));
        }
        for (size_t offset = row * stride + 12U;
             offset < (row + 1U) * stride; ++offset) {
            RDP_ASSERT_EQ(bgra[offset], static_cast<uint8_t>(0xA5));
        }
    }
}

RDP_TEST_CASE(vnc_zrle_direct_bgra_covers_speed_and_balanced_pixel_formats) {
    const std::array<VncRfbProtocol::PixelFormat, 2> formats = {
        rgb332Format(), rgb565Format(),
    };
    const std::array<std::vector<uint8_t>, 2> solidRedTiles = {
        std::vector<uint8_t> {1, 0xE0},
        std::vector<uint8_t> {1, 0x00, 0xF8},
    };
    for (size_t index = 0; index < formats.size(); ++index) {
        std::array<uint8_t, 4> bgra = {0, 0, 0, 0};
        std::string error;
        RDP_ASSERT(VncRfbProtocol::decodeZrleTilesToBgra(
            formats[index], 1, 1,
            solidRedTiles[index].data(), solidRedTiles[index].size(),
            bgra.data(), bgra.size(), 4U, error));
        RDP_ASSERT_EQ(bgra[0], static_cast<uint8_t>(0));
        RDP_ASSERT_EQ(bgra[1], static_cast<uint8_t>(0));
        RDP_ASSERT_EQ(bgra[2], static_cast<uint8_t>(255));
        RDP_ASSERT_EQ(bgra[3], static_cast<uint8_t>(255));
    }
}

RDP_TEST_CASE(vnc_zrle_parallel_direct_decode_matches_rgba_reference) {
    const VncRfbProtocol::PixelFormat format = rgba8888Format();
    constexpr int width = 640;
    constexpr int height = 512;
    const int columns = (width + 63) / 64;
    const int rows = (height + 63) / 64;
    std::vector<uint8_t> tiles;
    for (int tileY = 0; tileY < rows; ++tileY) {
        for (int tileX = 0; tileX < columns; ++tileX) {
            const bool red = ((tileX + tileY) & 1) == 0;
            tiles.push_back(1);
            tiles.push_back(static_cast<uint8_t>(red ? 0 : 255));
            tiles.push_back(0);
            tiles.push_back(static_cast<uint8_t>(red ? 255 : 0));
        }
    }

    std::vector<uint8_t> rgba;
    std::string error;
    RDP_ASSERT(VncRfbProtocol::decodeZrleTiles(
        format, width, height, tiles.data(), tiles.size(), rgba, error));
    std::vector<uint8_t> bgra(static_cast<size_t>(width) * height * 4U, 0);
    RDP_ASSERT(VncRfbProtocol::decodeZrleTilesToBgra(
        format, width, height, tiles.data(), tiles.size(),
        bgra.data(), bgra.size(), static_cast<size_t>(width) * 4U, error));
    RDP_ASSERT_EQ(bgra.size(), rgba.size());
    for (size_t offset = 0; offset < rgba.size(); offset += 4U) {
        RDP_ASSERT_EQ(bgra[offset], rgba[offset + 2U]);
        RDP_ASSERT_EQ(bgra[offset + 1U], rgba[offset + 1U]);
        RDP_ASSERT_EQ(bgra[offset + 2U], rgba[offset]);
        RDP_ASSERT_EQ(bgra[offset + 3U], rgba[offset + 3U]);
    }
}

RDP_TEST_CASE(vnc_zrle_direct_decode_fails_without_crossing_destination_bounds) {
    const VncRfbProtocol::PixelFormat format = rgba8888Format();
    const std::vector<uint8_t> malformed = {128, 0, 0, 255, 5};
    std::vector<uint8_t> guarded(32, 0x5A);
    std::string error;
    RDP_ASSERT(!VncRfbProtocol::decodeZrleTilesToBgra(
        format, 3, 1, malformed.data(), malformed.size(),
        guarded.data() + 8U, 12U, 12U, error));
    for (size_t index = 0; index < 8U; ++index) {
        RDP_ASSERT_EQ(guarded[index], static_cast<uint8_t>(0x5A));
    }
    for (size_t index = 20U; index < guarded.size(); ++index) {
        RDP_ASSERT_EQ(guarded[index], static_cast<uint8_t>(0x5A));
    }
    RDP_ASSERT(!VncRfbProtocol::decodeZrleTilesToBgra(
        format, 3, 1, malformed.data(), malformed.size(),
        guarded.data() + 8U, 11U, 12U, error));
}

RDP_TEST_CASE(vnc_zrle_rejects_palette_reuse_truncation_run_overflow_and_trailing_data) {
    const VncRfbProtocol::PixelFormat format = rgba8888Format();
    std::string error;
    std::vector<uint8_t> rgba;
    const std::vector<uint8_t> paletteReuse = {127};
    RDP_ASSERT(!VncRfbProtocol::decodeZrleTiles(
        format, 1, 1, paletteReuse.data(), paletteReuse.size(), rgba, error));
    const std::vector<uint8_t> rlePaletteReuse = {129};
    RDP_ASSERT(!VncRfbProtocol::decodeZrleTiles(
        format, 1, 1, rlePaletteReuse.data(), rlePaletteReuse.size(), rgba, error));
    const std::vector<uint8_t> truncated = {0, 0, 0};
    RDP_ASSERT(!VncRfbProtocol::decodeZrleTiles(
        format, 1, 1, truncated.data(), truncated.size(), rgba, error));
    const std::vector<uint8_t> runOverflow = {128, 0, 0, 255, 1};
    RDP_ASSERT(!VncRfbProtocol::decodeZrleTiles(
        format, 1, 1, runOverflow.data(), runOverflow.size(), rgba, error));
    const std::vector<uint8_t> trailing = {1, 0, 0, 255, 0};
    RDP_ASSERT(!VncRfbProtocol::decodeZrleTiles(
        format, 1, 1, trailing.data(), trailing.size(), rgba, error));
}

RDP_TEST_CASE(vnc_zrle_malformed_corpus_fails_closed_without_partial_output) {
    const VncRfbProtocol::PixelFormat format = rgba8888Format();
    const std::vector<std::vector<uint8_t>> malformed = {
        {},
        {17},
        {126},
        {127},
        {129},
        {1},
        {2, 0, 0, 255},
        {2, 0, 0, 255, 255, 0, 0},
        {128, 0, 0, 255},
        {128, 0, 0, 255, 255},
        {130, 0, 0, 255, 255, 0, 0, 2},
        {130, 0, 0, 255, 255, 0, 0, 0x80, 255},
        {255},
    };
    for (const std::vector<uint8_t>& bytes : malformed) {
        std::vector<uint8_t> rgba = {1, 2, 3, 4};
        std::string error;
        const uint8_t* data = bytes.empty() ? nullptr : bytes.data();
        RDP_ASSERT(!VncRfbProtocol::decodeZrleTiles(
            format, 3, 1, data, bytes.size(), rgba, error));
        RDP_ASSERT(rgba.empty());
        RDP_ASSERT(!error.empty());
    }
}

RDP_TEST_CASE(vnc_zrle_connection_stream_is_persistent_bounded_and_flush_checked) {
    z_stream compressor {};
    RDP_ASSERT_EQ(deflateInit(&compressor, Z_DEFAULT_COMPRESSION), Z_OK);
    const std::vector<uint8_t> firstPlain = {1, 0, 0, 255};
    const std::vector<uint8_t> secondPlain = {1, 0, 255, 0};
    const std::vector<uint8_t> firstCompressed =
        deflateSyncFlush(compressor, firstPlain);
    const std::vector<uint8_t> secondCompressed =
        deflateSyncFlush(compressor, secondPlain);
    deflateEnd(&compressor);
    RDP_ASSERT(!firstCompressed.empty());
    RDP_ASSERT(!secondCompressed.empty());

    VncRfbProtocol::ZrleInflater inflater;
    std::vector<uint8_t> output;
    std::string error;
    RDP_ASSERT(inflater.inflateChunk(
        firstCompressed.data(), firstCompressed.size(), 64, output, error));
    RDP_ASSERT(output == firstPlain);
    RDP_ASSERT(inflater.inflateChunk(
        secondCompressed.data(), secondCompressed.size(), 64, output, error));
    RDP_ASSERT(output == secondPlain);

    VncRfbProtocol::ZrleInflater truncatedInflater;
    RDP_ASSERT(!truncatedInflater.inflateChunk(
        firstCompressed.data(), firstCompressed.size() - 1, 64, output, error));

    z_stream bombCompressor {};
    RDP_ASSERT_EQ(deflateInit(&bombCompressor, Z_BEST_COMPRESSION), Z_OK);
    const std::vector<uint8_t> largePlain(4096, 0);
    const std::vector<uint8_t> bomb =
        deflateSyncFlush(bombCompressor, largePlain);
    deflateEnd(&bombCompressor);
    VncRfbProtocol::ZrleInflater boundedInflater;
    RDP_ASSERT(!boundedInflater.inflateChunk(
        bomb.data(), bomb.size(), 128, output, error));
}

RDP_TEST_CASE(vnc_zrle_decompressed_bound_is_finite_for_large_rectangles) {
    const VncRfbProtocol::PixelFormat format = rgba8888Format();
    size_t bound = 0;
    RDP_ASSERT(VncRfbProtocol::maxZrleDecodedBytes(2940, 1912, format, bound));
    RDP_ASSERT(bound > static_cast<size_t>(2940) * 1912 * 3);
    RDP_ASSERT(bound < static_cast<size_t>(64) * 1024 * 1024);
    RDP_ASSERT(!VncRfbProtocol::maxZrleDecodedBytes(0, 1912, format, bound));
}

RDP_TEST_CASE(vnc_frame_request_rate_policy_is_deterministic) {
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeFrameRateLimit(0), 0);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeFrameRateLimit(15), 15);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeFrameRateLimit(60), 60);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeFrameRateLimit(37), 30);
    RDP_ASSERT_EQ(VncRfbProtocol::framebufferRequestIntervalMs(0), static_cast<uint64_t>(0));
    RDP_ASSERT_EQ(VncRfbProtocol::framebufferRequestIntervalMs(15), static_cast<uint64_t>(67));
    RDP_ASSERT_EQ(VncRfbProtocol::framebufferRequestIntervalMs(30), static_cast<uint64_t>(34));
    RDP_ASSERT_EQ(VncRfbProtocol::framebufferRequestIntervalMs(60), static_cast<uint64_t>(17));
}

RDP_TEST_CASE(vnc_ultravnc_mode12_field_is_exactly_250_bytes) {
    std::array<uint8_t, VncRfbProtocol::kUltraVncRepeaterFieldBytes> field = {0};
    std::string error;
    RDP_ASSERT(VncRfbProtocol::buildRepeaterTargetField("1234", field, error));
    RDP_ASSERT_EQ(field[0], static_cast<uint8_t>('I'));
    RDP_ASSERT_EQ(field[1], static_cast<uint8_t>('D'));
    RDP_ASSERT_EQ(field[2], static_cast<uint8_t>(':'));
    RDP_ASSERT_EQ(field[3], static_cast<uint8_t>('1'));
    RDP_ASSERT_EQ(field[6], static_cast<uint8_t>('4'));
    RDP_ASSERT_EQ(field[7], static_cast<uint8_t>(0));
    RDP_ASSERT_EQ(field.size(), VncRfbProtocol::kUltraVncRepeaterFieldBytes);

    std::string target;
    RDP_ASSERT(VncRfbProtocol::parseRepeaterTargetField(field.data(), field.size(), target, error));
    RDP_ASSERT(target == "1234");
}

RDP_TEST_CASE(vnc_ultravnc_mode2_fixture_uses_same_server_field_contract) {
    std::array<uint8_t, VncRfbProtocol::kUltraVncRepeaterFieldBytes> field = {0};
    std::string error;
    // Mode2 is the repeater's server-side listener. Its fixed field is still
    // covered here as a byte fixture, while the viewer transport rejects it.
    RDP_ASSERT(VncRfbProtocol::buildRepeaterTargetField("ID-42", field, error));
    RDP_ASSERT(vncNativeRepeaterViewerModeIsAvailable("mode12"));
    RDP_ASSERT(!vncNativeRepeaterViewerModeIsAvailable("mode2"));
}

RDP_TEST_CASE(vnc_ultravnc_banner_and_short_or_invalid_fields_fail_closed) {
    static constexpr char banner[] = "RFB 000.000\n";
    RDP_ASSERT(VncRfbProtocol::isUltraVncRepeaterBanner(
        reinterpret_cast<const uint8_t*>(banner), VncRfbProtocol::kProtocolVersionBytes));
    static constexpr char wrongBanner[] = "RFB 003.008\n";
    RDP_ASSERT(!VncRfbProtocol::isUltraVncRepeaterBanner(
        reinterpret_cast<const uint8_t*>(wrongBanner), VncRfbProtocol::kProtocolVersionBytes));

    std::array<uint8_t, VncRfbProtocol::kUltraVncRepeaterFieldBytes> field = {0};
    std::string error;
    std::string target;
    RDP_ASSERT(!VncRfbProtocol::parseRepeaterTargetField(field.data(), field.size() - 1,
                                                         target, error));
    field[0] = 'I';
    field[1] = 'D';
    field[2] = ':';
    field[3] = '1';
    field[8] = 'x';
    RDP_ASSERT(!VncRfbProtocol::parseRepeaterTargetField(field.data(), field.size(), target, error));
}

RDP_TEST_CASE(vnc_ultravnc_target_validation_rejects_empty_control_and_overflow) {
    std::array<uint8_t, VncRfbProtocol::kUltraVncRepeaterFieldBytes> field = {0};
    std::string error;
    RDP_ASSERT(!VncRfbProtocol::buildRepeaterTargetField("", field, error));
    RDP_ASSERT(!VncRfbProtocol::buildRepeaterTargetField("bad\nID", field, error));
    RDP_ASSERT(!VncRfbProtocol::buildRepeaterTargetField(
        std::string(VncRfbProtocol::kUltraVncRepeaterFieldBytes - 2, 'x'), field, error));
}
