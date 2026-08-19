#ifndef RDP_AUTH_MODE_POLICY_H
#define RDP_AUTH_MODE_POLICY_H

#include <string>

enum class RdpAuthenticationPolicyMode {
    Password,
    BlankPassword,
    RestrictedAdmin
};

enum class RdpRestrictedAdminSecretPolicySource {
    NtlmHash
};

struct RdpAuthenticationPolicy {
    bool valid = false;
    RdpAuthenticationPolicyMode mode = RdpAuthenticationPolicyMode::Password;
    RdpRestrictedAdminSecretPolicySource restrictedAdminSecretSource =
        RdpRestrictedAdminSecretPolicySource::NtlmHash;
    std::string normalizedNtlmHash;
};

enum class RdpTransportSecurityMode {
    Nla,
    TlsWithoutNla
};

struct RdpTransportSecurityPolicy {
    bool valid = false;
    RdpTransportSecurityMode mode = RdpTransportSecurityMode::Nla;
    bool nlaSecurity = true;
    bool tlsSecurity = true;
    bool rdpSecurity = false;
    unsigned int requestedProtocols = 0x00000003; // SSL | HYBRID
    const char* errorCode = "";
};

/** Normalizes a 32-character NTLM hash, allowing only surrounding or embedded whitespace. */
std::string NormalizeRdpNtlmPasswordHash(const std::string& value);

/**
 * Parses untrusted NAPI strings.
 *
 * Restricted Admin accepts only a caller-supplied 32-character NTLM hash.
 * Password/blank-password modes must not receive a hash accidentally.
 */
RdpAuthenticationPolicy ParseRdpAuthenticationPolicy(const std::string& mode,
                                                      const std::string& restrictedAdminSecretSource,
                                                      const std::string& ntlmHash);

/**
 * Resolves the real FreeRDP security request.
 *
 * TLS-without-NLA is an explicit compatibility escape hatch for a direct
 * password session whose Windows endpoint no longer requires NLA.  It must
 * never silently alter the default NLA path, RD Gateway, Restricted Admin,
 * blank-password, or Standard RDP Security behavior.
 */
RdpTransportSecurityPolicy ResolveRdpTransportSecurityPolicy(
    bool tlsWithoutNlaRequested,
    bool nonDirectRoute,
    RdpAuthenticationPolicyMode authenticationMode);

#endif // RDP_AUTH_MODE_POLICY_H
