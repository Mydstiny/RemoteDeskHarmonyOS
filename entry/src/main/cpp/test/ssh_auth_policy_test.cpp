#include "test_runner.h"
#include "ssh/ssh_auth_policy.h"

RDP_TEST_CASE(ssh_auth_method_list_matches_exact_tokens) {
    RDP_ASSERT(sshAuthMethodAdvertised("publickey,password,keyboard-interactive",
                                      "password"));
    RDP_ASSERT(sshAuthMethodAdvertised("publickey, password", "password"));
    RDP_ASSERT(!sshAuthMethodAdvertised("publickey,password", "pass"));
    RDP_ASSERT(!sshAuthMethodAdvertised("publickey", "keyboard-interactive"));
}

RDP_TEST_CASE(ssh_password_fallback_requires_advertised_keyboard_interactive) {
    RDP_ASSERT(sshPasswordFallbackAllowsKeyboardInteractive(
        "publickey,keyboard-interactive", -18));
    RDP_ASSERT(!sshPasswordFallbackAllowsKeyboardInteractive(
        "publickey,password", -18));
    RDP_ASSERT(!sshPasswordFallbackAllowsKeyboardInteractive(
        "publickey,keyboard-interactive", 0));
}
