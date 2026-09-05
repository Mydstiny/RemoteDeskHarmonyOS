#pragma once

#include "extensions/protocol_adapter.h"
#include "rdp_network_recovery_policy.h"

#include <cstddef>
#include <string>

class RdpReconnectCredentialPolicy final {
public:
    static void secureClear(std::string& value) {
        if (!value.empty()) {
            volatile char* data = value.data();
            for (size_t index = 0; index < value.size(); ++index) {
                data[index] = '\0';
            }
        }
        value.clear();
    }

    static void clear(ConnectionConfig& config) {
        secureClear(config.password);
        secureClear(config.rdpRestrictedAdminHash);
    }

    static void replace(
        ConnectionConfig& destination, const ConnectionConfig& source) {
        clear(destination);
        try {
            destination = source;
        } catch (...) {
            // ConnectionConfig copy assignment can fail after copying one of
            // the secret fields. Scrub any partially assigned credentials
            // before propagating the allocation failure.
            clear(destination);
            throw;
        }
    }

    static bool clearIfStillRetired(
        ConnectionConfig& config, const RdpNetworkRecoveryPolicy& policy,
        uint64_t retirementToken) {
        if (!policy.isRetired(retirementToken)) {
            return false;
        }
        clear(config);
        return true;
    }

    // Terminal recovery paths that cannot reconnect must retire the exact
    // owner and scrub both reconnect credential forms as one production-used
    // policy operation. Callers serialize access to ConnectionConfig.
    static bool retireOwnerAndClear(
        ConnectionConfig& config, RdpNetworkRecoveryPolicy& policy) {
        const uint64_t retirementToken = policy.retireConnectionOwner();
        return clearIfStillRetired(config, policy, retirementToken);
    }

    static bool requiresUserResubmission(const ConnectionConfig& config) {
        return config.rdpAuthMode == RdpAuthenticationMode::RestrictedAdmin;
    }
};
