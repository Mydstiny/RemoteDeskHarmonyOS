#ifndef SSH_ERROR_H
#define SSH_ERROR_H

#include "ssh_route_policy.h"

// SSH adapter and auxiliary-operation errors. Keep the values stable because
// ArkTS surfaces them as part of the native operation contract.
enum SshError {
    ERR_SSH_SUCCESS             =  0,

    // TCP layer (-1x)
    ERR_SSH_SOCKET_CREATE       = -11,
    ERR_SSH_SOCKET_CONNECT      = -12,
    ERR_SSH_CONNECT_TIMEOUT     = -13,
    ERR_SSH_DNS_RESOLVE         = -14,
    ERR_SSH_BANNER_INVALID      = -15,
    ERR_SSH_PROXY_INVALID       = -16,
    ERR_SSH_PROXY_AUTH          = -17,
    ERR_SSH_PROXY_FAILED        = -18,
    ERR_SSH_PROXY_UNSUPPORTED   = kSshProxyUnsupportedError,

    // SSH protocol layer (-2x)
    ERR_SSH_SESSION_INIT        = -21,
    ERR_SSH_KEX_FAILED          = -22,
    ERR_SSH_KEX_TIMEOUT         = -23,
    ERR_SSH_HOSTKEY_MISMATCH    = -24,

    // Authentication layer (-3x)
    ERR_SSH_AUTH_FAILED         = -31,
    ERR_SSH_AUTH_TIMEOUT        = -32,
    ERR_SSH_AUTH_METHODS        = -33,
    ERR_SSH_AUTH_PARTIAL        = -34,
    ERR_SSH_AUTH_CANCELLED      = -35,

    // Channel layer (-4x)
    ERR_SSH_CHANNEL_OPEN        = -41,
    ERR_SSH_CHANNEL_CLOSED      = -42,
    ERR_SSH_PTY_FAILED          = -43,
    ERR_SSH_SHELL_FAILED        = -44,
    ERR_SSH_COMMAND_TIMEOUT     = -45,
    ERR_SSH_SUBSYSTEM_FAILED    = -46,

    // Data-transfer layer (-5x)
    ERR_SSH_READ_FAILED         = -51,
    ERR_SSH_WRITE_FAILED        = -52,
    ERR_SSH_SESSION_CLOSED      = -53,
    ERR_SSH_OUTPUT_LIMIT        = -54,
    ERR_SSH_REACTOR_QUEUE_FULL  = -55,
    ERR_SSH_SFTP_DURABILITY_UNSUPPORTED = -56,
    ERR_SSH_SESSION_STALE       = -57,
};

#endif // SSH_ERROR_H
