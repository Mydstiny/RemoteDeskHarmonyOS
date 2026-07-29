/**
 * vnc_rfb_protocol.h - pure byte-level contracts shared by the VNC runtime
 * and the host-side native tests.
 */
#ifndef VNC_RFB_PROTOCOL_H
#define VNC_RFB_PROTOCOL_H

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace VncRfbProtocol {

constexpr size_t kProtocolVersionBytes = 12;
constexpr size_t kUltraVncRepeaterFieldBytes = 250;

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

} // namespace VncRfbProtocol

#endif // VNC_RFB_PROTOCOL_H
