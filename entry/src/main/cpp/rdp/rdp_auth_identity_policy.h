#ifndef RDP_AUTH_IDENTITY_POLICY_H
#define RDP_AUTH_IDENTITY_POLICY_H

#include <string>

enum RdpAuthIdentityMode {
    RDP_AUTH_IDENTITY_MICROSOFT_PREFIX = 0,
    RDP_AUTH_IDENTITY_MICROSOFT_DOMAIN = 1,
    RDP_AUTH_IDENTITY_BARE_EMAIL = 2,
    RDP_AUTH_IDENTITY_AZUREAD_DOT_DOMAIN = 3,
    RDP_AUTH_IDENTITY_AZUREAD_DOMAIN = 4,
};

struct RdpAuthIdentity {
    std::string username;
    std::string domain;
    std::string modeName;
};

RdpAuthIdentity NormalizeRdpAuthIdentity(const std::string& username,
                                         const std::string& domain,
                                         int mode);

#endif // RDP_AUTH_IDENTITY_POLICY_H
