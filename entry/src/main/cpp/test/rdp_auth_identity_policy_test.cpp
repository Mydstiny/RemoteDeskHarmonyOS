#include "test_runner.h"
#include "rdp/rdp_auth_identity_policy.h"

RDP_TEST_CASE(rdp_auth_identity_defaults_microsoft_email_to_domain_mode) {
    const RdpAuthIdentity identity =
        NormalizeRdpAuthIdentity("user@example.com", "", RDP_AUTH_IDENTITY_MICROSOFT_DOMAIN);
    RDP_ASSERT(identity.username == "user@example.com");
    RDP_ASSERT(identity.domain == "MicrosoftAccount");
}

RDP_TEST_CASE(rdp_auth_identity_splits_microsoft_account_prefix_to_domain_mode) {
    const RdpAuthIdentity identity =
        NormalizeRdpAuthIdentity("MicrosoftAccount\\user@example.com", "",
                                 RDP_AUTH_IDENTITY_MICROSOFT_DOMAIN);
    RDP_ASSERT(identity.username == "user@example.com");
    RDP_ASSERT(identity.domain == "MicrosoftAccount");
}

RDP_TEST_CASE(rdp_auth_identity_supports_freerdp_azuread_dot_domain_format) {
    const RdpAuthIdentity identity =
        NormalizeRdpAuthIdentity("user@corp.example", "", RDP_AUTH_IDENTITY_AZUREAD_DOT_DOMAIN);
    RDP_ASSERT(identity.username == "AzureAD\\user@corp.example");
    RDP_ASSERT(identity.domain == ".");
}

RDP_TEST_CASE(rdp_auth_identity_supports_azuread_domain_format) {
    const RdpAuthIdentity identity =
        NormalizeRdpAuthIdentity("user@corp.example", "", RDP_AUTH_IDENTITY_AZUREAD_DOMAIN);
    RDP_ASSERT(identity.username == "user@corp.example");
    RDP_ASSERT(identity.domain == "AzureAD");
}

RDP_TEST_CASE(rdp_auth_identity_preserves_explicit_domain_users) {
    const RdpAuthIdentity identity =
        NormalizeRdpAuthIdentity("WORKGROUP\\alice", "", RDP_AUTH_IDENTITY_MICROSOFT_DOMAIN);
    RDP_ASSERT(identity.username == "alice");
    RDP_ASSERT(identity.domain == "WORKGROUP");
}
