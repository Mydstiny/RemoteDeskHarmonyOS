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

RDP_TEST_CASE(ssh_password_fallback_preserves_interactive_outcome) {
    RDP_ASSERT(sshPasswordFallbackFinalResult(-33, -35) == -35);
    RDP_ASSERT(sshPasswordFallbackFinalResult(-31, -32) == -32);
    RDP_ASSERT(sshPasswordFallbackFinalResult(-31, -34) == -34);
    RDP_ASSERT(sshPasswordFallbackFinalResult(-33, 0) == 0);
}

RDP_TEST_CASE(ssh_password_auth_respects_advertised_methods) {
    RDP_ASSERT(sshPasswordAuthShouldAttempt(""));
    RDP_ASSERT(sshPasswordAuthShouldAttempt("publickey,password"));
    RDP_ASSERT(!sshPasswordAuthShouldAttempt("publickey,keyboard-interactive"));
    RDP_ASSERT(!sshPasswordAuthShouldAttempt("publickey"));
}

RDP_TEST_CASE(ssh_keyboard_interactive_password_fallback_requires_hidden_prompt) {
    RDP_ASSERT(sshKeyboardInteractivePromptCanUsePassword(false));
    RDP_ASSERT(!sshKeyboardInteractivePromptCanUsePassword(true));
}

RDP_TEST_CASE(ssh_keyboard_interactive_password_fallback_is_single_use) {
    RDP_ASSERT(sshKeyboardInteractivePasswordFallbackCanAutofill(1, false, false));
    RDP_ASSERT(!sshKeyboardInteractivePasswordFallbackCanAutofill(1, true, false));
    RDP_ASSERT(!sshKeyboardInteractivePasswordFallbackCanAutofill(2, false, false));
    RDP_ASSERT(!sshKeyboardInteractivePasswordFallbackCanAutofill(1, false, true));
}
