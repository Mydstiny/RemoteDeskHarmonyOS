/**
 * SSH authentication method list policy.
 *
 * libssh2 returns a comma-separated method list. Keep the parser independent
 * from a live session so fallback decisions can be tested without credentials.
 */
#ifndef SSH_AUTH_POLICY_H
#define SSH_AUTH_POLICY_H

#include <cstddef>
#include <string>

inline bool sshAuthMethodAdvertised(const std::string& methods, const char* wanted) {
    if (wanted == nullptr || *wanted == '\0') {
        return false;
    }
    const std::string target(wanted);
    size_t start = 0;
    while (start <= methods.size()) {
        const size_t end = methods.find(',', start);
        const size_t length = end == std::string::npos ? methods.size() - start : end - start;
        size_t first = start;
        while (first < start + length &&
               (methods[first] == ' ' || methods[first] == '\t')) {
            ++first;
        }
        size_t last = start + length;
        while (last > first && (methods[last - 1] == ' ' || methods[last - 1] == '\t')) {
            --last;
        }
        if (last - first == target.size() && methods.compare(first, target.size(), target) == 0) {
            return true;
        }
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }
    return false;
}

inline bool sshPasswordFallbackAllowsKeyboardInteractive(
    const std::string& methods, int passwordResult) {
    return passwordResult != 0 &&
        sshAuthMethodAdvertised(methods, "keyboard-interactive");
}

inline int sshPasswordFallbackFinalResult(
    int passwordResult, int keyboardInteractiveResult) {
    (void)passwordResult;
    // The fallback method was actually attempted, so its cancellation,
    // timeout or authentication result is the user-visible outcome.
    return keyboardInteractiveResult;
}

/**
 * An advertised method list is authoritative when it is non-empty.  Calling
 * a method the server did not advertise can consume a PAM challenge or make
 * some older servers close the authentication exchange before the fallback
 * method gets a chance to run.
 */
inline bool sshPasswordAuthShouldAttempt(const std::string& methods) {
    return methods.empty() || sshAuthMethodAdvertised(methods, "password");
}

inline bool sshKeyboardInteractivePromptCanUsePassword(bool echo) {
    // Password/PAM prompts are non-echoing.  Never put the account password
    // into a visible username/OTP challenge unless the caller supplied an
    // explicit response in the ordered response list.
    return !echo;
}

inline bool sshKeyboardInteractivePasswordFallbackCanAutofill(
    size_t promptCount, bool echo, bool passwordFallbackUsed) {
    // A saved account password may satisfy the first PAM-style password
    // question, but it must never be replayed into a later MFA/OTP round or
    // duplicated across a multi-prompt challenge.
    return !passwordFallbackUsed && promptCount == 1 &&
        sshKeyboardInteractivePromptCanUsePassword(echo);
}

#endif
