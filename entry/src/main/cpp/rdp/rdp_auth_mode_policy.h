#ifndef RDP_AUTH_MODE_POLICY_H
#define RDP_AUTH_MODE_POLICY_H

#include <string>

enum class RdpAuthenticationPolicyMode {
    Password,
    BlankPassword,
    RestrictedAdmin
};

enum class RdpRestrictedAdminSecretPolicySource {
    NtlmHash,
    EmptyPasswordHash
};

struct RdpAuthenticationPolicy {
    bool valid = false;
    RdpAuthenticationPolicyMode mode = RdpAuthenticationPolicyMode::Password;
    RdpRestrictedAdminSecretPolicySource restrictedAdminSecretSource =
        RdpRestrictedAdminSecretPolicySource::NtlmHash;
    std::string normalizedNtlmHash;
};

/** Normalizes a 32-character NTLM hash, allowing only surrounding or embedded whitespace. */
std::string NormalizeRdpNtlmPasswordHash(const std::string& value);

/** Parses untrusted NAPI strings without retaining an irrelevant password hash. */
RdpAuthenticationPolicy ParseRdpAuthenticationPolicy(const std::string& mode,
                                                      const std::string& restrictedAdminSecretSource,
                                                      const std::string& ntlmHash);

#endif // RDP_AUTH_MODE_POLICY_H
