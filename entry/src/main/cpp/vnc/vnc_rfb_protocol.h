/**
 * vnc_rfb_protocol.h - pure byte-level contracts shared by the VNC runtime
 * and the host-side native tests.
 */
#ifndef VNC_RFB_PROTOCOL_H
#define VNC_RFB_PROTOCOL_H

#include "vnc_pixel_format.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace VncRfbProtocol {

constexpr size_t kProtocolVersionBytes = 12;
constexpr size_t kUltraVncRepeaterFieldBytes = 250;
constexpr int kDesktopSizeEncoding = -223;
constexpr int kLastRectEncoding = -224;
constexpr int kRawEncoding = 0;
constexpr int kCopyRectEncoding = 1;
constexpr int kZrleEncoding = 16;
/** The RFB ClientInit shared flag. A viewer always sends one byte. */
uint8_t clientInitSharedFlag();

/**
 * Normalize an advertised RFB 3.x minor version to a published wire
 * dialect. RFC 6143 defines 3.3, 3.7 and 3.8; other 3.x values are handled
 * as 3.3 rather than being silently upgraded to a newer dialect.
 */
int normalizeRfbMinor(int advertisedMinor);

/**
 * Whether the negotiated security type is followed by SecurityResult.
 * RFB 3.3/3.7 None proceed directly to ClientInit; RFB 3.8 None and VNC
 * Authentication use SecurityResult.
 */
bool securityResultExpected(int negotiatedMinor, uint8_t selectedSecurityType);

/**
 * Build an RFB FramebufferUpdateRequest. The wire message is exactly
 * message-type, incremental, x, y, width and height (10 bytes total); unlike
 * SetPixelFormat and SetEncodings it has no padding byte.
 */
std::vector<uint8_t> buildFramebufferUpdateRequest(bool incremental,
                                                   uint16_t width,
                                                   uint16_t height);

/**
 * Resolve the requested true-colour depth. Explicit 8/16/32-bit choices win;
 * auto uses 16-bit for the speed preset or large RAW desktops and 32-bit
 * otherwise.
 */
int effectiveTrueColorDepth(const std::string& requestedDepth,
                            const std::string& qualityPreset,
                            uint64_t desktopPixels);

/** Build the exact 20-byte SetPixelFormat packet for 8/16/32-bit true colour. */
std::vector<uint8_t> buildSetPixelFormat(int colorDepth);

/**
 * Build the SetEncodings packet. ZRLE is preferred for auto/zrle and omitted
 * for an explicit raw request; Raw remains the mandatory fallback. Cursor,
 * DesktopSize and LastRect are always advertised.
 */
std::vector<uint8_t> buildSetEncodings(const std::string& preferredEncoding);

/** Normalize the only supported VNC frame-rate limits. Zero means unbounded. */
int normalizeFrameRateLimit(int frameRateLimit);

/** Minimum interval between framebuffer update requests for the rate limit. */
uint64_t framebufferRequestIntervalMs(int frameRateLimit);

/** UltraVNC mode12 sends this exact repeater banner to a viewer. */
bool isUltraVncRepeaterBanner(const uint8_t* data, size_t size);

/**
 * Build the fixed-width display/proxy field consumed by the official
 * UltraVNC repeater listeners. The field is "ID:<target>" followed by NUL
 * padding and is exactly 250 bytes; it does not contain a newline.
 */
bool buildRepeaterTargetField(const std::string& target,
                              std::array<uint8_t, kUltraVncRepeaterFieldBytes>& field,
                              std::string& error);

/** Parse the same fixed-width field and return the target without the ID:. */
bool parseRepeaterTargetField(const uint8_t* data, size_t size, std::string& target,
                              std::string& error);

/** Number of bytes in a ZRLE CPIXEL for the negotiated true-colour format. */
size_t compactPixelBytes(const PixelFormat& format);

/** Maximum valid decompressed byte count for one bounded ZRLE rectangle. */
bool maxZrleDecodedBytes(int width, int height, const PixelFormat& format,
                         size_t& maxBytes);

/**
 * Decode the uncompressed tile stream for one ZRLE rectangle into tightly
 * packed RGBA bytes. The output contains exactly width*height*4 bytes.
 */
bool decodeZrleTiles(const PixelFormat& format, int width, int height,
                     const uint8_t* data, size_t size,
                     std::vector<uint8_t>& rgba, std::string& error);

/**
 * Connection-scoped RFC 6143 ZRLE inflater. One instance must be retained for
 * the entire RFB connection because successive rectangles share one zlib
 * stream.
 */
class ZrleInflater {
public:
    ZrleInflater();
    ~ZrleInflater();
    ZrleInflater(const ZrleInflater&) = delete;
    ZrleInflater& operator=(const ZrleInflater&) = delete;

    bool inflateChunk(const uint8_t* compressed, size_t compressedSize,
                      size_t maxOutputBytes, std::vector<uint8_t>& output,
                      std::string& error);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace VncRfbProtocol

#endif // VNC_RFB_PROTOCOL_H
