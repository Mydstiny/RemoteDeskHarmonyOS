#ifndef REMOTEDESK_MOONLIGHT_REQUEST_UUID_H
#define REMOTEDESK_MOONLIGHT_REQUEST_UUID_H

#include <array>
#include <cstdint>
#include <string>

namespace remotedesk::moonlight {

// Formats caller-provided entropy as an RFC 4122 version-4 UUID. This seam is
// shared by product composition and deterministic host tests.
bool formatMoonlightRequestUuidV4(
    const std::array<std::uint8_t, 16U>& entropy,
    std::string& output) noexcept;

// Returns an empty string if the platform CSPRNG is unavailable.
std::string generateMoonlightRequestUuid() noexcept;

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_REQUEST_UUID_H
