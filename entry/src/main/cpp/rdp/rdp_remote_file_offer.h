#ifndef RDP_REMOTE_FILE_OFFER_H
#define RDP_REMOTE_FILE_OFFER_H
#include "rdp_transfer_types.h"
#include <cstddef>

namespace RdpRemoteFileOffer {
constexpr uint32_t kMaxEntries = 1024;
constexpr uint64_t kMaxTotalBytes = 16ULL * 1024 * 1024 * 1024;
constexpr size_t kDescriptorBytes = 592;
constexpr size_t kMaxDescriptorBytes = 4 + kMaxEntries * kDescriptorBytes;
RemoteClipboardFileOffer parse(const uint8_t* data, size_t size, uint64_t sequence, uint32_t flags);
bool safeRelativeName(const std::string& input, std::string& normalized);
}
#endif
