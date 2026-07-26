/**
 * vnc_transport_policy.h - native VNC transport enablement contract.
 *
 * The ArkTS gateway policy is not a sufficient security boundary because a
 * native caller can construct ConnectionConfig directly. Keep the native
 * allowlist equally narrow until a versioned gateway contract is deployed.
 */
#ifndef VNC_TRANSPORT_POLICY_H
#define VNC_TRANSPORT_POLICY_H

#include <string>

inline bool vncNativeTransportIsAvailable(const std::string& transport) {
    return transport == "direct_tcp" || transport == "ultravnc_repeater";
}

/** A HarmonyOS VNC client is a viewer; mode2 is the repeater's server side. */
inline bool vncNativeRepeaterViewerModeIsAvailable(const std::string& mode) {
    return mode == "mode12";
}

#endif // VNC_TRANSPORT_POLICY_H
