/**
 * rdp_certificate_policy_test.cpp - RDP certificate fingerprint policy tests
 */

#include "test_runner.h"
#include "rdp/rdp_certificate_policy.h"

RDP_TEST_CASE(rdp_certificate_policy_matches_common_sha256_formats) {
    const std::string hex =
        "AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899";

    RDP_ASSERT(RdpCertificatePolicy::FingerprintMatches("sha256:" + hex, hex));
    RDP_ASSERT(RdpCertificatePolicy::FingerprintMatches(
        "sha256:" + hex,
        "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:"
        "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"));
}

RDP_TEST_CASE(rdp_certificate_policy_formats_freerdp_accepted_fingerprint) {
    const std::string fp =
        "sha256:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:"
        "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99";

    RDP_ASSERT(
        RdpCertificatePolicy::ToFreeRdpAcceptedFingerprint(fp) ==
        "sha256:aabbccddeeff00112233445566778899"
        "aabbccddeeff00112233445566778899");
}

RDP_TEST_CASE(rdp_certificate_policy_rejects_incomplete_sha256_fingerprints) {
    RDP_ASSERT(RdpCertificatePolicy::NormalizeFingerprint("sha256:aabbccdd").empty());
    RDP_ASSERT(RdpCertificatePolicy::ToFreeRdpAcceptedFingerprint("sha256:aabbccdd").empty());
    RDP_ASSERT(!RdpCertificatePolicy::FingerprintMatches(
        "sha256:aabbccdd",
        "sha256:aabbccdd"));
}
