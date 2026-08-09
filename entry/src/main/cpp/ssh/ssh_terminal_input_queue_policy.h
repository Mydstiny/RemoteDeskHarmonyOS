#ifndef REMOTEDESK_SSH_TERMINAL_INPUT_QUEUE_POLICY_H
#define REMOTEDESK_SSH_TERMINAL_INPUT_QUEUE_POLICY_H

#include <cstddef>
#include <cstdint>

// The queue itself remains owned by SshAdapter. This small, allocation-free
// policy is shared by production admission and host tests so quota and stale
// generation semantics cannot silently drift.
class SshTerminalInputQueuePolicy final {
public:
    static constexpr size_t kMaxItems = 256;
    static constexpr size_t kMaxBytes = 256 * 1024;
    static constexpr size_t kMaxControlItems = 64;
    static constexpr size_t kMaxControlBytes = 16 * 1024;
    static constexpr size_t kMaxDataItems = kMaxItems - kMaxControlItems;
    static constexpr size_t kMaxDataBytes = kMaxBytes - kMaxControlBytes;

    enum class Admission {
        ACCEPTED,
        QUEUE_FULL,
        STALE_GENERATION,
        INVALID,
    };

    static Admission admit(size_t depth, size_t bytes,
                           size_t controlItems, size_t controlBytes,
                           size_t dataItems, size_t dataBytes,
                           size_t incomingBytes, bool control,
                           uint64_t expectedGeneration,
                           uint64_t actualGeneration) noexcept {
        if (incomingBytes == 0 || incomingBytes > kMaxBytes) {
            return Admission::INVALID;
        }
        if (expectedGeneration != 0 && expectedGeneration != actualGeneration) {
            return Admission::STALE_GENERATION;
        }
        if (depth >= kMaxItems || bytes > kMaxBytes - incomingBytes) {
            return Admission::QUEUE_FULL;
        }
        if (control) {
            if (incomingBytes > kMaxControlBytes ||
                controlItems >= kMaxControlItems ||
                controlBytes > kMaxControlBytes - incomingBytes) {
                return Admission::QUEUE_FULL;
            }
        } else if (incomingBytes > kMaxDataBytes ||
                   dataItems >= kMaxDataItems ||
                   dataBytes > kMaxDataBytes - incomingBytes) {
            return Admission::QUEUE_FULL;
        }
        return Admission::ACCEPTED;
    }
};

#endif // REMOTEDESK_SSH_TERMINAL_INPUT_QUEUE_POLICY_H
