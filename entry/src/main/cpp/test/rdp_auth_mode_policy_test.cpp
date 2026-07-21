#include "test_runner.h"
#include "rdp/rdp_auth_mode_policy.h"

RDP_TEST_CASE(rdp_auth_mode_normalizes_restricted_admin_ntlm_hash) {
    const RdpAuthenticationPolicy policy = ParseRdpAuthenticationPolicy(
        "restricted_admin", "ntlm_hash", " 0123456789abcdef 0123456789abcdef ");
    RDP_ASSERT(policy.valid);
    RDP_ASSERT(policy.mode == RdpAuthenticationPolicyMode::RestrictedAdmin);
    RDP_ASSERT(policy.restrictedAdminSecretSource == RdpRestrictedAdminSecretPolicySource::NtlmHash);
    RDP_ASSERT(policy.normalizedNtlmHash == "0123456789ABCDEF0123456789ABCDEF");
}

RDP_TEST_CASE(rdp_auth_mode_rejects_invalid_restricted_admin_hash) {
    const RdpAuthenticationPolicy policy = ParseRdpAuthenticationPolicy(
        "restricted_admin", "ntlm_hash", "this-is-not-an-ntlm-hash");
    RDP_ASSERT(!policy.valid);
    RDP_ASSERT(policy.normalizedNtlmHash.empty());
}

RDP_TEST_CASE(rdp_auth_mode_uses_empty_password_hash_source_without_forwarding_user_hash) {
    const RdpAuthenticationPolicy policy = ParseRdpAuthenticationPolicy(
        "restricted_admin", "empty_password_hash", "0123456789abcdef0123456789abcdef");
    RDP_ASSERT(policy.valid);
    RDP_ASSERT(policy.restrictedAdminSecretSource ==
               RdpRestrictedAdminSecretPolicySource::EmptyPasswordHash);
    RDP_ASSERT(policy.normalizedNtlmHash.empty());
}

RDP_TEST_CASE(rdp_auth_mode_blank_password_drops_irrelevant_hash) {
    const RdpAuthenticationPolicy policy = ParseRdpAuthenticationPolicy(
        "blank_password", "ntlm_hash", "0123456789abcdef0123456789abcdef");
    RDP_ASSERT(policy.valid);
    RDP_ASSERT(policy.mode == RdpAuthenticationPolicyMode::BlankPassword);
    RDP_ASSERT(policy.normalizedNtlmHash.empty());
}
