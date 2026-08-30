#include "ssh/ssh_sensitive_buffer.h"
#include "test_runner.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace {

bool returnThroughStringGuard(std::string& value) {
    SshSensitiveBufferGuard<std::string> guard(value);
    return false;
}

bool returnThroughByteGuard(std::vector<std::uint8_t>& value) {
    SshSensitiveBufferGuard<std::vector<std::uint8_t>> guard(value);
    return false;
}

bool returnThroughStringCollectionGuard(std::vector<std::string>& values) {
    SshSensitiveStringCollectionGuard<std::vector<std::string>> guard(values);
    return false;
}

} // namespace

RDP_TEST_CASE(ssh_sensitive_string_guard_wipes_early_return_payload) {
    std::string value = "user:proxy-password";
    const std::size_t originalSize = value.size();
    RDP_ASSERT(!returnThroughStringGuard(value));
    RDP_ASSERT(value.size() == originalSize);
    RDP_ASSERT(std::all_of(value.begin(), value.end(), [](char byte) {
        return byte == '\0';
    }));
}

RDP_TEST_CASE(ssh_sensitive_byte_guard_wipes_early_return_payload) {
    std::vector<std::uint8_t> value {1, 4, 'u', 's', 'e', 'r', 8,
                                     'p', 'a', 's', 's', 'w', 'o', 'r', 'd'};
    const std::size_t originalSize = value.size();
    RDP_ASSERT(!returnThroughByteGuard(value));
    RDP_ASSERT(value.size() == originalSize);
    RDP_ASSERT(std::all_of(value.begin(), value.end(), [](std::uint8_t byte) {
        return byte == 0;
    }));
}

RDP_TEST_CASE(ssh_sensitive_string_collection_guard_wipes_every_response) {
    std::vector<std::string> values {"first-otp", "", "second-password"};
    RDP_ASSERT(!returnThroughStringCollectionGuard(values));
    RDP_ASSERT(values.size() == 3);
    RDP_ASSERT(std::all_of(values[0].begin(), values[0].end(), [](char byte) {
        return byte == '\0';
    }));
    RDP_ASSERT(values[1].empty());
    RDP_ASSERT(std::all_of(values[2].begin(), values[2].end(), [](char byte) {
        return byte == '\0';
    }));
}

RDP_TEST_CASE(ssh_sensitive_allocation_registry_wipes_before_library_free) {
    constexpr std::size_t kSecretSize = 10;
    const std::size_t baseline =
        sshSensitiveAllocationRegistry().pendingCount();
    auto* allocation = static_cast<char*>(
        sshAllocateTrackedSensitive(kSecretSize));
    RDP_ASSERT(allocation != nullptr);
    RDP_ASSERT(sshSensitiveAllocationRegistry().pendingCount() == baseline + 1);
    const char secret[kSecretSize] = {'o', 't', 'p', '-', '1', '2', '3', '4', '5', '6'};
    std::copy(secret, secret + kSecretSize, allocation);

    // The production libssh2 free callback invokes this exact operation
    // before std::free(). Inspect while the allocation is still valid.
    RDP_ASSERT(sshSensitiveAllocationRegistry().wipeAndForget(allocation));
    RDP_ASSERT(std::all_of(
        allocation, allocation + kSecretSize,
        [](char byte) { return byte == '\0'; }));
    std::free(allocation);
    RDP_ASSERT(sshSensitiveAllocationRegistry().pendingCount() == baseline);
}

RDP_TEST_CASE(ssh_sensitive_append_reserves_before_first_secret_byte) {
    std::string request(31, 'H');
    request.shrink_to_fit();
    const std::string encodedCredential(257, 'S');
    bool stableAllocation = false;
    {
        SshSensitiveBufferGuard<std::string> guard(request);
        constexpr std::size_t kHeaderAndTerminatorsSize = 31U;
        const std::size_t appendSize =
            kHeaderAndTerminatorsSize + encodedCredential.size();
        RDP_ASSERT(sshReserveSensitiveAppend(request, appendSize));
        const char* const reservedAllocation = request.data();
        const std::size_t reservedCapacity = request.capacity();
        request.append(kHeaderAndTerminatorsSize, 'A');
        request.append(encodedCredential);
        stableAllocation = request.data() == reservedAllocation &&
            request.capacity() == reservedCapacity;
    }
    RDP_ASSERT(stableAllocation);
    RDP_ASSERT(std::all_of(request.begin(), request.end(), [](char byte) {
        return byte == '\0';
    }));
}

RDP_TEST_CASE(ssh_sensitive_append_rejects_size_overflow_before_reserve) {
    std::string request = "non-secret-prefix";
    RDP_ASSERT(!sshReserveSensitiveAppend(request, request.max_size()));
    RDP_ASSERT(request == "non-secret-prefix");
}
