#include "rdp_auth_identity_policy.h"

#include <cstring>

namespace {

constexpr const char* kMicrosoftAccount = "MicrosoftAccount";
constexpr const char* kAzureAd = "AzureAD";

bool startsWith(const std::string& value, const char* prefix) {
    const std::size_t len = std::strlen(prefix);
    return value.size() >= len && value.compare(0, len, prefix) == 0;
}

bool containsEmailMarker(const std::string& value) {
    return value.find('@') != std::string::npos;
}

RdpAuthIdentity splitDomainUser(const std::string& value, const char* modeName) {
    const std::size_t slash = value.find('\\');
    if (slash == std::string::npos || slash == 0 || slash >= value.size() - 1) {
        return { value, "", modeName };
    }
    return { value.substr(slash + 1), value.substr(0, slash), modeName };
}

std::string stripPrefix(const std::string& value, const char* prefix) {
    return startsWith(value, prefix) ? value.substr(std::strlen(prefix)) : value;
}

std::string stripMicrosoftPrefix(const std::string& value) {
    return stripPrefix(value, "MicrosoftAccount\\");
}

std::string stripAzureAdPrefix(const std::string& value) {
    std::string user = stripPrefix(value, ".\\AzureAD\\");
    user = stripPrefix(user, "\\AzureAD\\");
    user = stripPrefix(user, "AzureAD\\");
    return user;
}

} // namespace

RdpAuthIdentity NormalizeRdpAuthIdentity(const std::string& username,
                                         const std::string& domain,
                                         int mode) {
    if (username.empty()) {
        return { username, domain, "empty" };
    }

    if (mode == RDP_AUTH_IDENTITY_AZUREAD_DOT_DOMAIN) {
        const std::string user = stripAzureAdPrefix(username);
        return { std::string(kAzureAd) + "\\" + user, ".", "azuread-dot-domain" };
    }

    if (mode == RDP_AUTH_IDENTITY_AZUREAD_DOMAIN) {
        const std::string user = stripAzureAdPrefix(username);
        return { user, kAzureAd, "azuread-domain" };
    }

    if (startsWith(username, ".\\AzureAD\\") || startsWith(username, "\\AzureAD\\") ||
        startsWith(username, "AzureAD\\")) {
        return NormalizeRdpAuthIdentity(username, domain, RDP_AUTH_IDENTITY_AZUREAD_DOT_DOMAIN);
    }

    if (username.find('\\') != std::string::npos && !startsWith(username, "MicrosoftAccount\\")) {
        return splitDomainUser(username, "explicit-domain");
    }

    if (startsWith(username, "MicrosoftAccount\\") || containsEmailMarker(username)) {
        const std::string email = stripMicrosoftPrefix(username);
        if (mode == RDP_AUTH_IDENTITY_BARE_EMAIL) {
            return { email, "", "bare-email" };
        }
        if (mode == RDP_AUTH_IDENTITY_MICROSOFT_PREFIX) {
            return { startsWith(username, "MicrosoftAccount\\") ? username :
                std::string(kMicrosoftAccount) + "\\" + email, "", "microsoft-prefix" };
        }
        return { email, kMicrosoftAccount, "microsoft-domain" };
    }

    return { username, domain, "plain" };
}
