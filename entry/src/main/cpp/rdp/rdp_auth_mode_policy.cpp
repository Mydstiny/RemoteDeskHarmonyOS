#include "rdp_auth_mode_policy.h"

#include <cctype>

std::string NormalizeRdpNtlmPasswordHash(const std::string& value) {
    std::string normalized;
    normalized.reserve(value.size());
    for (const unsigned char character : value) {
        if (std::isspace(character)) {
            continue;
        }
        if (!std::isxdigit(character)) {
            return "";
        }
        normalized.push_back(static_cast<char>(std::toupper(character)));
    }
    return normalized.size() == 32 ? normalized : "";
}

RdpAuthenticationPolicy ParseRdpAuthenticationPolicy(const std::string& mode,
                                                      const std::string& restrictedAdminSecretSource,
                                                      const std::string& ntlmHash) {
    RdpAuthenticationPolicy result;
    if (mode.empty() || mode == "password") {
        result.mode = RdpAuthenticationPolicyMode::Password;
    } else if (mode == "blank_password") {
        result.mode = RdpAuthenticationPolicyMode::BlankPassword;
    } else if (mode == "restricted_admin") {
        result.mode = RdpAuthenticationPolicyMode::RestrictedAdmin;
    } else {
        return result;
    }

    if (restrictedAdminSecretSource.empty() || restrictedAdminSecretSource == "ntlm_hash") {
        result.restrictedAdminSecretSource = RdpRestrictedAdminSecretPolicySource::NtlmHash;
    } else if (restrictedAdminSecretSource == "empty_password_hash") {
        result.restrictedAdminSecretSource = RdpRestrictedAdminSecretPolicySource::EmptyPasswordHash;
    } else {
        return result;
    }

    if (result.mode == RdpAuthenticationPolicyMode::RestrictedAdmin &&
        result.restrictedAdminSecretSource == RdpRestrictedAdminSecretPolicySource::NtlmHash) {
        result.normalizedNtlmHash = NormalizeRdpNtlmPasswordHash(ntlmHash);
        if (result.normalizedNtlmHash.empty()) {
            return result;
        }
    }
    result.valid = true;
    return result;
}
